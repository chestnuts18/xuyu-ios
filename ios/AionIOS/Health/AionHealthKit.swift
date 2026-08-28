import Foundation
import HealthKit

/// 健康上报核心：HealthKit 授权 + 后台投递观察 + 样本拉取去重
/// 采集扩展（2026-08-16）：3 类 → 13 类 + 睡眠聚合，metadata 对齐 health_monitor.py 解析
@MainActor
final class AionHealthKit: ObservableObject {
    static let shared = AionHealthKit()

    private let store = HKHealthStore()
    @Published var authorized = false
    @Published var lastUploadInfo = "尚未上传"
    private var foregroundLoopStarted = false
    private var uploadedUUIDs: Set<String> = []
    private var uploadedSleepSignatures: [String: String] = [:]
    private let uuidKey = "health_uploaded_uuids"
    private let sleepKey = "health_uploaded_sleep_signatures"

    /// 高频：45 分钟窗口（Watch 同步快）
    private let frequentTypes: [HKQuantityTypeIdentifier] = [
        .heartRate,
        .stepCount,
        .activeEnergyBurned,
        .distanceWalkingRunning,
        .appleExerciseTime,
        .appleStandTime,
        .flightsClimbed,
    ]

    /// 低频：24 小时窗口（静息心率/HRV/血氧/睡眠样本次日凌晨才同步，45 分钟会漏）
    private let infrequentTypes: [HKQuantityTypeIdentifier] = [
        .restingHeartRate,
        .heartRateVariabilitySDNN,
        .oxygenSaturation,
        .respiratoryRate,
        .basalEnergyBurned,
        .walkingHeartRateAverage,
        .bodyMass,
        // 体能指标（2026-08-25 念宝拍板「全套都要」）：VO2Max/心率恢复
        .vo2Max,
        .heartRateRecoveryOneMinute,
        // 步态分析（手表自动测）
        .walkingSpeed,
        .walkingStepLength,
        .walkingDoubleSupportPercentage,
        .walkingAsymmetryPercentage,
        // 跑步动力学（手表跑步才有值）
        .runningPower,
        .runningVerticalOscillation,
        .runningGroundContactTime,
        // 耳机音量暴露
        .headphoneAudioExposure,
    ]

    private let sleepType: HKCategoryType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!

    private var allQuantityTypes: [HKQuantityTypeIdentifier] { frequentTypes + infrequentTypes }

    private init() {
        uploadedUUIDs = Set(UserDefaults.standard.stringArray(forKey: uuidKey) ?? [])
        uploadedSleepSignatures = UserDefaults.standard.dictionary(forKey: sleepKey) as? [String: String] ?? [:]
        uploadedWorkoutUUIDs = Set(UserDefaults.standard.stringArray(forKey: workoutUUIDKey) ?? [])
        refreshAuthStatus()
    }

    func refreshAuthStatus() {
        var all: [HKObjectType] = []
        for id in allQuantityTypes {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { all.append(t) }
        }
        all.append(sleepType)
        // 授权容错（2026-08-18）：任一类别已授权即视为可用，只传已授权的类型；
        // 旧逻辑要求 14 类全开，缺一类整个上传循环空转
        let granted = all.filter { store.authorizationStatus(for: $0) == .sharingAuthorized }
        authorized = !granted.isEmpty
        // 状态分布：0=未决定 1=被拒 2=已授权（定位授权弹窗死点用）
        var dist = [0, 0, 0]
        for t in all { dist[Int(store.authorizationStatus(for: t).rawValue)] += 1 }
        AionLogger.shared.log("hk auth refresh: authorized=\(authorized) notDet=\(dist[0]) denied=\(dist[1]) granted=\(dist[2])")
    }

    func requestAuthorization() async {
        var read: Set<HKSampleType> = []
        for id in allQuantityTypes {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { read.insert(t) }
        }
        read.insert(sleepType)
        AionLogger.shared.log("hk requestAuth begin, types=\(read.count)")
        do {
            try await store.requestAuthorization(toShare: [], read: read)
            AionLogger.shared.log("hk requestAuth returned ok")
        } catch {
            // 授权弹窗失败/被系统拦：记日志定位（之前静默吞掉查不出来）
            AionLogger.shared.log("hk requestAuth error: \(error.localizedDescription)")
            refreshAuthStatus()
            return
        }
        refreshAuthStatus()
        guard authorized else {
            AionLogger.shared.log("hk requestAuth end: still not authorized")
            return
        }
        // 后台投递：Watch 数据同步到 iPhone 时系统唤醒本 App 拉新样本
        var observed: Set<HKSampleType> = []
        for id in allQuantityTypes {
            guard let t = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            observed.insert(t)
        }
        observed.insert(sleepType)
        for type in observed {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, _, error in
                guard error == nil else { return }
                Task { await self?.uploadRecentSamples() }
            }
            store.execute(query)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
    }

    /// 前台兜底：每 5 分钟拉一次（后台投递不可靠时的保底通道）
    func startForegroundLoop() {
        guard !foregroundLoopStarted else { return }
        foregroundLoopStarted = true
        AionLogger.shared.log("hk loop started, authorized=\(authorized)")
        Task { await uploadRecentSamples() }
        Task {
            while true {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                await uploadRecentSamples()
                // 健康循环 = 5 分钟唤醒源，顺带喂设备感知层
                DeviceSense.shared.tick("health")
            }
        }
    }

    func uploadRecentSamples() async {
        // 2026-08-18：不依赖 authorized 门——iOS 26.6 的 authorizationStatus 读接口有 bug
        // （系统健康 UI 显示全绿授权，但 API 返回 denied）。授权真不在时 query 返回空，
        // 无害；授权在时直接能查出来，绕过错误的读值。
        AionLogger.shared.log("hk upload cycle begin (authUI=\(authorized))")
        await uploadQuantities(frequentTypes, window: 45 * 60)
        await uploadQuantities(infrequentTypes, window: 24 * 3600)
        await uploadSleep(window: 24 * 3600)
        await uploadWorkouts(window: 72 * 3600)
        AionLogger.shared.log("hk upload cycle end, lastInfo=\(lastUploadInfo)")
    }

    // MARK: - 锻炼记录（HKWorkout → POST /api/health/workouts，运动教练链路 2026-08-25）

    private var uploadedWorkoutUUIDs: Set<String> = []
    private let workoutUUIDKey = "health_uploaded_workout_uuids"

    private func uploadWorkouts(window: TimeInterval) async {
        let end = Date()
        let start = end.addingTimeInterval(-window)
        let samples: [HKWorkout] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: HKQuery.predicateForSamples(
                    withStart: start, end: end, options: .strictStartDate
                ),
                limit: HKObjectQueryNoLimit, sortDescriptors: nil
            ) { _, s, _ in
                continuation.resume(returning: (s as? [HKWorkout]) ?? [])
            }
            store.execute(query)
        }
        for w in samples {
            guard !uploadedWorkoutUUIDs.contains(w.uuid.uuidString) else { continue }
            let entry: [String: Any] = [
                "device_name": DeviceIdentity.deviceId,
                "workout_type": Self.workoutTypeName(w.workoutActivityType),
                "start_at": w.startDate.timeIntervalSince1970,
                "end_at": w.endDate.timeIntervalSince1970,
                "duration_min": round(w.duration / 60 * 10) / 10,
                "calories_burned": round(
                    (w.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? 0) * 10) / 10,
                "distance_km": round(
                    (w.totalDistance?.doubleValue(for: .meter()) ?? 0) / 1000 * 100) / 100,
                "source": "aion_ios",
            ]
            if await AionHealthUploader.shared.uploadWorkout(entry: entry) {
                uploadedWorkoutUUIDs.insert(w.uuid.uuidString)
                let arr = Array(uploadedWorkoutUUIDs).sorted().suffix(120)
                uploadedWorkoutUUIDs = Set(arr)
                UserDefaults.standard.set(Array(arr), forKey: workoutUUIDKey)
                AionLogger.shared.log(
                    "hk workout uploaded: \(Self.workoutTypeName(w.workoutActivityType))")
            }
        }
    }

    static func workoutTypeName(_ t: HKWorkoutActivityType) -> String {
        switch t {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .highIntensityIntervalTraining: return "hiit"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "strength"
        case .yoga: return "yoga"
        case .hiking: return "hiking"
        case .dance: return "dance"
        case .pilates: return "pilates"
        case .badminton, .tennis, .tableTennis: return "racket"
        default: return "other"
        }
    }

    // MARK: - Quantity 上报（UUID 去重，幂等）

    private func uploadQuantities(_ types: [HKQuantityTypeIdentifier], window: TimeInterval) async {
        let end = Date()
        let start = end.addingTimeInterval(-window)
        for id in types {
            guard let type = HKQuantityType.quantityType(forIdentifier: id) else { continue }
            // 不再逐类 guard authorizationStatus——iOS 26.6 读接口 bug（UI 全绿但 API 返回 denied），
            // 授权真不在时 query 返回空，无害
            let samples = await fetchQuantity(type: type, from: start, to: end)
            let fresh = samples.filter { !uploadedUUIDs.contains($0.uuid.uuidString) }
            guard !fresh.isEmpty else { continue }
            AionLogger.shared.log("hk fetch \(Self.typeName(for: id)): total=\(samples.count) fresh=\(fresh.count)")
            let unit = Self.unit(for: id)
            let metrics: [[String: Any]] = fresh.map { sample in
                var value = sample.quantity.doubleValue(for: unit)
                if id == .distanceWalkingRunning { value = value / 1000 }  // m → km
                return [
                    "type": Self.typeName(for: id),
                    "value": value,
                    "unit": Self.unitName(for: id),
                    "recorded_at": sample.endDate.timeIntervalSince1970,
                    "source": "aion_ios",
                ]
            }
            if await AionHealthUploader.shared.upload(metrics: metrics) {
                fresh.forEach { uploadedUUIDs.insert($0.uuid.uuidString) }
                pruneUploadedUUIDs()
                lastUploadInfo = "刚上传 \(fresh.count) 条样本"
            }
        }
    }

    // MARK: - 睡眠聚合（按睡眠结束日去重，一天传一次）

    private func uploadSleep(window: TimeInterval) async {
        let end = Date()
        let start = end.addingTimeInterval(-window)
        let samples = await fetchCategory(from: start, to: end)
        // 按 endDate 自然日分组（夜间睡眠可能跨天）
        var byDay: [String: [HKCategorySample]] = [:]
        for s in samples {
            byDay[Self.dayString(s.endDate), default: []].append(s)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for (day, daySamples) in byDay {
            var deep: TimeInterval = 0, core: TimeInterval = 0
            var rem: TimeInterval = 0, wake: TimeInterval = 0
            var sleepStart: Date?, sleepEnd: Date?
            for s in daySamples {
                let duration = s.endDate.timeIntervalSince(s.startDate)
                switch s.value {
                case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                    deep += duration
                case HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                     HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                    core += duration
                case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                    rem += duration
                case HKCategoryValueSleepAnalysis.awake.rawValue:
                    wake += duration
                default:
                    break
                }
                if sleepStart == nil || s.startDate < sleepStart! { sleepStart = s.startDate }
                if sleepEnd == nil || s.endDate > sleepEnd! { sleepEnd = s.endDate }
            }
            let totalH = (deep + core + rem) / 3600
            guard totalH > 0.1, let sleepStart, let sleepEnd else { continue }
            // 聚合签名：起止+总时长。与上次一致才跳过——午睡等新段并入后签名变化，覆盖式重发（服务器端按段去重）
            let signature = "\(formatter.string(from: sleepStart))|\(formatter.string(from: sleepEnd))|\(round(totalH * 10) / 10)"
            if uploadedSleepSignatures[day] == signature { continue }
            // 字段名对齐 health_monitor.py 睡眠解析（deep/core/rem/wake + sleepStart/sleepEnd）
            let meta: [String: Any] = [
                "deep": round(deep / 3600 * 10) / 10,
                "core": round(core / 3600 * 10) / 10,
                "rem": round(rem / 3600 * 10) / 10,
                "wake": round(wake / 3600 * 10) / 10,
                "sleepStart": formatter.string(from: sleepStart),
                "sleepEnd": formatter.string(from: sleepEnd),
            ]
            let metric: [String: Any] = [
                "type": "sleep_analysis",
                "value": round(totalH * 10) / 10,
                "unit": "h",
                "recorded_at": sleepEnd.timeIntervalSince1970,
                "source": "aion_ios",
                "metadata": meta,
            ]
            if await AionHealthUploader.shared.upload(metrics: [metric]) {
                uploadedSleepSignatures[day] = signature
                if uploadedSleepSignatures.count > 90 {
                    uploadedSleepSignatures = Dictionary(uploadedSleepSignatures.sorted { $0.key < $1.key }.suffix(90)) { $1 }
                }
                UserDefaults.standard.set(uploadedSleepSignatures, forKey: sleepKey)
                lastUploadInfo = "刚上传 \(day) 睡眠"
            }
        }
    }

    private func pruneUploadedUUIDs() {
        if uploadedUUIDs.count > 2000 {
            uploadedUUIDs = Set(uploadedUUIDs.sorted().suffix(1000))
        }
        UserDefaults.standard.set(Array(uploadedUUIDs), forKey: uuidKey)
    }

    // MARK: - 拉取

    private func fetchQuantity(type: HKQuantityType, from: Date, to: Date) async -> [HKQuantitySample] {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: from, end: to, options: .strictStartDate
            )
            let query = HKAnchoredObjectQuery(
                type: type, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit
            ) { _, samples, _, _, _ in
                continuation.resume(returning: (samples as? [HKQuantitySample]) ?? [])
            }
            store.execute(query)
        }
    }

    private func fetchCategory(from: Date, to: Date) async -> [HKCategorySample] {
        await withCheckedContinuation { continuation in
            let predicate = HKQuery.predicateForSamples(
                withStart: from, end: to, options: .strictStartDate
            )
            let query = HKAnchoredObjectQuery(
                type: sleepType, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit
            ) { _, samples, _, _, _ in
                continuation.resume(returning: (samples as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
    }

    // MARK: - 类型映射

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func typeName(for id: HKQuantityTypeIdentifier) -> String {
        switch id {
        case .heartRate: return "heart_rate"
        case .stepCount: return "step_count"
        case .activeEnergyBurned: return "active_energy"
        case .distanceWalkingRunning: return "walking_running_distance"
        case .appleExerciseTime: return "apple_exercise_time"
        case .appleStandTime: return "apple_stand_time"
        case .flightsClimbed: return "flights_climbed"
        case .restingHeartRate: return "resting_heart_rate"
        case .heartRateVariabilitySDNN: return "heart_rate_variability"
        case .oxygenSaturation: return "spo2"
        case .respiratoryRate: return "respiratory_rate"
        case .basalEnergyBurned: return "basal_energy_burned"
        case .walkingHeartRateAverage: return "walking_heart_rate_average"
        case .bodyMass: return "body_mass"
        case .vo2Max: return "vo2_max"
        case .heartRateRecoveryOneMinute: return "heart_rate_recovery"
        case .walkingSpeed: return "walking_speed"
        case .walkingStepLength: return "walking_step_length"
        case .walkingDoubleSupportPercentage: return "walking_double_support"
        case .walkingAsymmetryPercentage: return "walking_asymmetry"
        case .runningPower: return "running_power"
        case .runningVerticalOscillation: return "running_vertical_oscillation"
        case .runningGroundContactTime: return "running_ground_contact_time"
        case .headphoneAudioExposure: return "headphone_audio_exposure"
        default: return id.rawValue
        }
    }

    static func unitName(for id: HKQuantityTypeIdentifier) -> String {
        switch id {
        case .heartRate, .restingHeartRate, .respiratoryRate, .walkingHeartRateAverage,
             .heartRateRecoveryOneMinute:
            return "count/min"
        case .stepCount, .flightsClimbed: return "count"
        case .activeEnergyBurned, .basalEnergyBurned: return "kcal"
        case .distanceWalkingRunning: return "km"
        case .appleExerciseTime, .appleStandTime: return "min"
        case .heartRateVariabilitySDNN: return "ms"
        case .oxygenSaturation: return "%"
        case .bodyMass: return "kg"
        case .vo2Max: return "mL/kg/min"
        case .walkingSpeed: return "m/s"
        case .walkingStepLength: return "m"
        case .walkingDoubleSupportPercentage, .walkingAsymmetryPercentage: return "%"
        case .runningPower: return "W"
        case .runningVerticalOscillation: return "cm"
        case .runningGroundContactTime: return "ms"
        case .headphoneAudioExposure: return "dBASPL"
        default: return ""
        }
    }

    static func unit(for id: HKQuantityTypeIdentifier) -> HKUnit {
        switch id {
        case .heartRate, .restingHeartRate, .respiratoryRate, .walkingHeartRateAverage,
             .heartRateRecoveryOneMinute:
            return HKUnit.count().unitDivided(by: .minute())
        case .stepCount, .flightsClimbed:
            return .count()
        case .activeEnergyBurned, .basalEnergyBurned:
            return .kilocalorie()
        case .distanceWalkingRunning:
            return .meter()  // 上报时转 km
        case .appleExerciseTime, .appleStandTime:
            return .minute()
        case .heartRateVariabilitySDNN:
            return HKUnit.secondUnit(with: .milli)
        case .oxygenSaturation:
            return .percent()
        case .bodyMass:
            return HKUnit.gramUnit(with: .kilo)
        case .vo2Max:
            return HKUnit.literUnit(with: .milli)
                .unitDivided(by: .minute())
                .unitDivided(by: HKUnit.gramUnit(with: .kilo))
        case .walkingSpeed:
            return HKUnit.meter().unitDivided(by: .second())
        case .walkingStepLength:
            return .meter()
        case .walkingDoubleSupportPercentage, .walkingAsymmetryPercentage:
            return .percent()
        case .runningPower:
            return .watt()
        case .runningVerticalOscillation:
            return HKUnit.meterUnit(with: .centi)
        case .runningGroundContactTime:
            return HKUnit.secondUnit(with: .milli)
        case .headphoneAudioExposure:
            return .decibelAWeightedSoundPressureLevel()
        default:
            return .count()
        }
    }
}
