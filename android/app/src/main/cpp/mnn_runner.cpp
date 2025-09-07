// JNI bridge for running MNN models
#include <jni.h>
#include <string>
#include <vector>
#include <sstream>
#include <memory>
#include <cstring>
#include <random>
#include <chrono>
#include <map>
#include <iomanip>

#if HAVE_MNN
#include "MNN/Interpreter.hpp"
#include "MNN/Tensor.hpp"
#endif

static int mapForward(const std::string& s) {
#if HAVE_MNN
    if (s == "AUTO") return (int)MNN_FORWARD_AUTO;
    if (s == "CPU") return (int)MNN_FORWARD_CPU;
    if (s == "VULKAN") return (int)MNN_FORWARD_VULKAN;
    if (s == "OPENCL") return (int)MNN_FORWARD_OPENCL;
    if (s == "OPENGL" || s == "OPENGL_ES" || s == "OPENGL_ES3") return (int)MNN_FORWARD_OPENGL;
    if (s == "METAL") return (int)MNN_FORWARD_METAL;
    if (s == "CUDA") return (int)MNN_FORWARD_CUDA;
    if (s == "NN" || s == "NNAPI") return (int)MNN_FORWARD_NN;
    return (int)MNN_FORWARD_CPU;
#else
    (void)s; // unused
    return 0;
#endif
}

#if HAVE_MNN
static const char* forwardName(MNNForwardType t) {
    switch (t) {
        case MNN_FORWARD_CPU: return "CPU";
        case MNN_FORWARD_AUTO: return "AUTO";
        case MNN_FORWARD_METAL: return "METAL";
        case MNN_FORWARD_CUDA: return "CUDA";
        case MNN_FORWARD_OPENCL: return "OPENCL";
        case MNN_FORWARD_OPENGL: return "OPENGL";
        case MNN_FORWARD_VULKAN: return "VULKAN";
        case MNN_FORWARD_NN: return "NN";
        case MNN_FORWARD_ALL: return "ALL";
        default: return "UNKNOWN";
    }
}
#endif

extern "C" JNIEXPORT jstring JNICALL
Java_com_mnn_runner_mnn_1runner_1app_NativeBridge_runModel(
        JNIEnv* env,
        jobject /* this */,
        jstring modelPath,
        jintArray inputShape,
        jstring backend,
        jstring backupType,
        jstring memoryMode,
        jstring precisionMode,
        jstring powerMode,
        jstring inputFill,
        jint threads,
        jstring cacheFile) {
    const char* cModel = env->GetStringUTFChars(modelPath, nullptr);
    const char* cBackend = env->GetStringUTFChars(backend, nullptr);
    const char* cBackup = env->GetStringUTFChars(backupType, nullptr);

    jsize len = env->GetArrayLength(inputShape);
    std::vector<int> shape(len);
    env->GetIntArrayRegion(inputShape, 0, len, shape.data());

#if HAVE_MNN
    std::ostringstream out;
    try {
        std::unique_ptr<MNN::Interpreter> net(MNN::Interpreter::createFromFile(cModel));
        if (!net) throw std::runtime_error("Failed to create interpreter");

        // Optional: set cache file for GPU backends (OpenCL/Vulkan)
        const char* cCache = cacheFile ? env->GetStringUTFChars(cacheFile, nullptr) : nullptr;
        if (cCache && std::strlen(cCache) > 0) {
            net->setCacheFile(cCache);
        }

        MNN::ScheduleConfig cfg;
        cfg.type = (MNNForwardType)mapForward(cBackend);
        cfg.backupType = (MNNForwardType)mapForward(std::string(cBackup ? cBackup : "CPU"));
        cfg.numThread = threads > 0 ? threads : 1;

        MNN::BackendConfig bcfg;
        const char* cPrec = env->GetStringUTFChars(precisionMode, nullptr);
        std::string prec = cPrec ? std::string(cPrec) : std::string("NORMAL");
        if (prec == "LOW") bcfg.precision = MNN::BackendConfig::Precision_Low;
        else if (prec == "HIGH") bcfg.precision = MNN::BackendConfig::Precision_High;
        else bcfg.precision = MNN::BackendConfig::Precision_Normal;
        env->ReleaseStringUTFChars(precisionMode, cPrec);

        cfg.backendConfig = &bcfg;

        auto session = net->createSession(cfg);
        if (!session) throw std::runtime_error("Failed to create session");
        // Resize and fill all inputs; assume same shape when multiple inputs.
        auto inputs = net->getSessionInputAll(session);
        for (auto& kv : inputs) {
            auto* in = kv.second;
            if (!in) continue;
            net->resizeTensor(in, shape);
        }
        net->resizeSession(session);

        // Determine fill mode
        std::string fill = "ZERO";
        const char* cFill = env->GetStringUTFChars(inputFill, nullptr);
        if (cFill) fill = std::string(cFill);
        env->ReleaseStringUTFChars(inputFill, cFill);

        // Prepare RNG if needed
        std::mt19937 rng(42);
        std::uniform_real_distribution<float> uni(0.0f, 1.0f);
        std::normal_distribution<float> norm(0.0f, 1.0f);

        for (auto& kv : inputs) {
            auto* in = kv.second;
            if (!in) continue;
            auto host = std::make_shared<MNN::Tensor>(in, in->getDimensionType());
            auto bytes = host->size();
            auto code = host->getType().code;
            if (fill == "ONE" && code == halide_type_float) {
                float* ptr = host->host<float>();
                for (int i = 0; i < host->elementSize(); ++i) ptr[i] = 1.0f;
            } else if (fill == "UNIFORM" && code == halide_type_float) {
                float* ptr = host->host<float>();
                for (int i = 0; i < host->elementSize(); ++i) ptr[i] = uni(rng);
            } else if (fill == "NORMAL" && code == halide_type_float) {
                float* ptr = host->host<float>();
                for (int i = 0; i < host->elementSize(); ++i) ptr[i] = norm(rng);
            } else {
                // Default zeros for other types or ZERO fill
                std::memset(host->host<void>(), 0, bytes);
            }
            in->copyFromHostTensor(host.get());
        }

        net->runSession(session);

        auto outputs = net->getSessionOutputAll(session);
        bool first = true;
        for (auto& kv : outputs) {
            auto* t = kv.second;
            if (!first) out << ", ";
            first = false;
            out << kv.first << "[";
            for (int i = 0; i < t->dimensions(); ++i) {
                out << t->length(i);
                if (i + 1 < t->dimensions()) out << "x";
            }
            out << "]";
        }

        net->releaseSession(session);

        std::ostringstream msg;
        msg << "MNN 3.1.0 OK backend=" << cBackend << " outputs=" << out.str();

        env->ReleaseStringUTFChars(modelPath, cModel);
        env->ReleaseStringUTFChars(backend, cBackend);
        env->ReleaseStringUTFChars(backupType, cBackup);
        if (cCache) env->ReleaseStringUTFChars(cacheFile, cCache);
        const char* cMem = env->GetStringUTFChars(memoryMode, nullptr);
        env->ReleaseStringUTFChars(memoryMode, cMem);
        const char* cPow = env->GetStringUTFChars(powerMode, nullptr);
        env->ReleaseStringUTFChars(powerMode, cPow);

        return env->NewStringUTF(msg.str().c_str());
    } catch (const std::exception& e) {
        std::string err = std::string("MNN ERROR: ") + e.what();
        env->ReleaseStringUTFChars(modelPath, cModel);
        env->ReleaseStringUTFChars(backend, cBackend);
        env->ReleaseStringUTFChars(backupType, cBackup);
        const char* cCache2 = cacheFile ? env->GetStringUTFChars(cacheFile, nullptr) : nullptr;
        if (cCache2) env->ReleaseStringUTFChars(cacheFile, cCache2);
        const char* cMem = env->GetStringUTFChars(memoryMode, nullptr);
        env->ReleaseStringUTFChars(memoryMode, cMem);
        const char* cPow = env->GetStringUTFChars(powerMode, nullptr);
        env->ReleaseStringUTFChars(powerMode, cPow);
        return env->NewStringUTF(err.c_str());
    }
#else
    // Build-time stub path when MNN headers/libs not packaged
    env->ReleaseStringUTFChars(backupType, cBackup);
    const char* cCache = cacheFile ? env->GetStringUTFChars(cacheFile, nullptr) : nullptr;
    if (cCache) env->ReleaseStringUTFChars(cacheFile, cCache);
    const char* cMem = env->GetStringUTFChars(memoryMode, nullptr);
    env->ReleaseStringUTFChars(memoryMode, cMem);
    const char* cPow = env->GetStringUTFChars(powerMode, nullptr);
    env->ReleaseStringUTFChars(powerMode, cPow);
    const char* cFill = env->GetStringUTFChars(inputFill, nullptr);
    env->ReleaseStringUTFChars(inputFill, cFill);

    std::ostringstream msg;
    msg << "MNN not bundled. Place headers under src/main/cpp/third_party/MNN/include and libMNN.so under src/main/jniLibs/<ABI>/";
    env->ReleaseStringUTFChars(modelPath, cModel);
    env->ReleaseStringUTFChars(backend, cBackend);
    env->ReleaseStringUTFChars(backupType, cBackup);
    return env->NewStringUTF(msg.str().c_str());
#endif
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_mnn_runner_mnn_1runner_1app_NativeBridge_runModelProfile(
        JNIEnv* env,
        jobject /* this */,
        jstring modelPath,
        jintArray inputShape,
        jstring backend,
        jstring backupType,
        jstring memoryMode,
        jstring precisionMode,
        jstring powerMode,
        jstring inputFill,
        jint threads,
        jstring cacheFile) {
    const char* cModel = env->GetStringUTFChars(modelPath, nullptr);
    const char* cBackend = env->GetStringUTFChars(backend, nullptr);
    const char* cBackup = env->GetStringUTFChars(backupType, nullptr);

    jsize len = env->GetArrayLength(inputShape);
    std::vector<int> shape(len);
    env->GetIntArrayRegion(inputShape, 0, len, shape.data());

#if HAVE_MNN
    using clock = std::chrono::steady_clock;
    auto t0 = clock::now();
    std::ostringstream report;
    try {
        std::unique_ptr<MNN::Interpreter> net(MNN::Interpreter::createFromFile(cModel));
        if (!net) throw std::runtime_error("Failed to create interpreter");
        auto t1 = clock::now();

        // Optional cache file
        const char* cCache = cacheFile ? env->GetStringUTFChars(cacheFile, nullptr) : nullptr;
        if (cCache && std::strlen(cCache) > 0) {
            net->setCacheFile(cCache);
        }

        MNN::ScheduleConfig cfg;
        cfg.type = (MNNForwardType)mapForward(cBackend);
        cfg.backupType = (MNNForwardType)mapForward(std::string(cBackup ? cBackup : "CPU"));
        cfg.numThread = threads > 0 ? threads : 1;

        MNN::BackendConfig bcfg;
        const char* cPrec = env->GetStringUTFChars(precisionMode, nullptr);
        std::string prec = cPrec ? std::string(cPrec) : std::string("NORMAL");
        if (prec == "LOW") bcfg.precision = MNN::BackendConfig::Precision_Low;
        else if (prec == "HIGH") bcfg.precision = MNN::BackendConfig::Precision_High;
        else bcfg.precision = MNN::BackendConfig::Precision_Normal;
        env->ReleaseStringUTFChars(precisionMode, cPrec);
        cfg.backendConfig = &bcfg;

        auto t2_before = clock::now();
        auto session = net->createSession(cfg);
        if (!session) throw std::runtime_error("Failed to create session");
        auto t2 = clock::now();

        // Resize and set input
        auto inputs = net->getSessionInputAll(session);
        for (auto& kv : inputs) {
            auto* in = kv.second;
            if (!in) continue;
            net->resizeTensor(in, shape);
        }
        auto t3_before = clock::now();
        net->resizeSession(session);
        auto t3 = clock::now();

        // Determine fill mode
        std::string fill = "ZERO";
        const char* cFill = env->GetStringUTFChars(inputFill, nullptr);
        if (cFill) fill = std::string(cFill);
        env->ReleaseStringUTFChars(inputFill, cFill);

        std::mt19937 rng(42);
        std::uniform_real_distribution<float> uni(0.0f, 1.0f);
        std::normal_distribution<float> norm(0.0f, 1.0f);

        for (auto& kv : inputs) {
            auto* in = kv.second;
            if (!in) continue;
            auto host = std::make_shared<MNN::Tensor>(in, in->getDimensionType());
            auto bytes = host->size();
            auto code = host->getType().code;
            if (fill == "ONE" && code == halide_type_float) {
                float* ptr = host->host<float>();
                for (int i = 0; i < host->elementSize(); ++i) ptr[i] = 1.0f;
            } else if (fill == "UNIFORM" && code == halide_type_float) {
                float* ptr = host->host<float>();
                for (int i = 0; i < host->elementSize(); ++i) ptr[i] = uni(rng);
            } else if (fill == "NORMAL" && code == halide_type_float) {
                float* ptr = host->host<float>();
                for (int i = 0; i < host->elementSize(); ++i) ptr[i] = norm(rng);
            } else {
                std::memset(host->host<void>(), 0, bytes);
            }
            in->copyFromHostTensor(host.get());
        }

        // Collect session info helpers
        auto dur_ms = [](clock::time_point a, clock::time_point b) {
            return std::chrono::duration_cast<std::chrono::duration<double, std::milli>>(b - a).count();
        };

        int threadsInfo = cfg.numThread;
        (void)net->getSessionInfo(session, MNN::Interpreter::THREAD_NUMBER, &threadsInfo);
        int beBuf[16] = {0};
        bool hasBE = net->getSessionInfo(session, MNN::Interpreter::BACKENDS, beBuf);

        struct OpPerf { std::string name; std::string type; double ms = 0.0; double start = 0.0; double end = 0.0; uint64_t deviceId = 0; std::string backend; };
        std::vector<OpPerf> ops;
        std::map<const MNN::OperatorInfo*, size_t> indexByPtr;
        std::map<const MNN::OperatorInfo*, clock::time_point> startByPtr;

        auto pickGpuLabel = [&](int primaryType) -> const char* {
            // Decide which GPU backend label to use for device-backed ops
            auto isGpu = [](int t) {
                return t == (int)MNN_FORWARD_OPENCL || t == (int)MNN_FORWARD_OPENGL ||
                       t == (int)MNN_FORWARD_VULKAN || t == (int)MNN_FORWARD_CUDA ||
                       t == (int)MNN_FORWARD_METAL || t == (int)MNN_FORWARD_NN;
            };
            if (primaryType == (int)MNN_FORWARD_AUTO || primaryType == (int)MNN_FORWARD_CPU) {
                if (hasBE) {
                    for (int i = 0; i < 16; ++i) {
                        int v = beBuf[i];
                        if (v == 0 && i > 0) break;
                        if (v < 0 || v > 20) continue;
                        if (isGpu(v)) return forwardName((MNNForwardType)v);
                    }
                }
                return "CPU";
            }
            if (isGpu(primaryType)) return forwardName((MNNForwardType)primaryType);
            return "CPU";
        };
        const int primaryType = mapForward(cBackend);
        const char* gpuLabel = pickGpuLabel(primaryType);

        clock::time_point runStartAnchor; // set before runSessionWithCallBackInfo
        auto before = [&](const std::vector<MNN::Tensor*>& tensors, const MNN::OperatorInfo* info) {
            (void)tensors;
            startByPtr[info] = clock::now();
            return true;
        };
        auto after = [&](const std::vector<MNN::Tensor*>& tensors, const MNN::OperatorInfo* info) {
            auto tEnd = clock::now();
            OpPerf rec;
            rec.name = info ? info->name() : std::string("op");
            rec.type = info ? info->type() : std::string("unknown");
            auto it = startByPtr.find(info);
            if (it != startByPtr.end()) {
                rec.ms = dur_ms(it->second, tEnd);
                rec.start = dur_ms(runStartAnchor, it->second);
                rec.end = dur_ms(runStartAnchor, tEnd);
            }
            if (!tensors.empty() && tensors[0]) {
                rec.deviceId = tensors[0]->deviceId();
            }
            // Label backend per-op: CPU for host, otherwise map to selected GPU label
            rec.backend = rec.deviceId ? std::string(gpuLabel) : std::string("CPU");
            ops.emplace_back(std::move(rec));
            return true;
        };
        runStartAnchor = clock::now();
        // High-level run only (no per-op callbacks)
        net->runSession(session);
        auto t4 = clock::now();

        auto outputs = net->getSessionOutputAll(session);
        std::ostringstream outShapes;
        bool first = true;
        for (auto& kv : outputs) {
            auto* t = kv.second;
            if (!t) continue;
            if (!first) outShapes << ", ";
            first = false;
            outShapes << kv.first << "[";
            for (int i = 0; i < t->dimensions(); ++i) {
                outShapes << t->length(i);
                if (i + 1 < t->dimensions()) outShapes << "x";
            }
            outShapes << "]";
        }

        // Build JSON report
        std::ostringstream json;
        json.setf(std::ios::fixed); json.precision(3);
        json << "{";
        json << "\"profile\":true,";
        json << "\"backend\":\"" << forwardName((MNNForwardType)mapForward(cBackend)) << "\",";
        json << "\"backup\":\"" << forwardName((MNNForwardType)mapForward(std::string(cBackup ? cBackup : "CPU"))) << "\",";
        json << "\"threads\":" << threadsInfo << ",";
        json << "\"metrics\":{"
             << "\"createInterpreter_ms\":" << dur_ms(t0, t1) << ","
             << "\"createSession_ms\":" << dur_ms(t2_before, t2) << ","
             << "\"resizeSession_ms\":" << dur_ms(t3_before, t3) << ","
             << "\"runSession_ms\":" << dur_ms(runStartAnchor, t4) << "},";
        // outputs shapes
        json << "\"outputs\":[";
        {
            bool f = true;
            for (auto& kv : outputs) {
                auto* t = kv.second; if (!t) continue;
                if (!f) json << ","; f = false;
                json << "{\"name\":\"" << kv.first << "\",\"shape\":[";
                for (int i = 0; i < t->dimensions(); ++i) {
                    if (i) json << ",";
                    json << t->length(i);
                }
                json << "]}";
            }
        }
        json << "],";
        // ops
        json << "\"ops\":[";
        for (size_t i = 0; i < ops.size(); ++i) {
            const auto& op = ops[i];
            if (i) json << ",";
            json << "{\"index\":" << (i+1)
                 << ",\"type\":\"" << op.type << "\""
                 << ",\"name\":\"" << op.name << "\""
                 << ",\"backend\":\"" << op.backend << "\""
                 << ",\"start_ms\":" << op.start
                 << ",\"end_ms\":" << op.end
                 << ",\"duration_ms\":" << op.ms
                 << "}";
        }
        json << "]}";

        net->releaseSession(session);

        env->ReleaseStringUTFChars(modelPath, cModel);
        env->ReleaseStringUTFChars(backend, cBackend);
        env->ReleaseStringUTFChars(backupType, cBackup);
        if (cCache) env->ReleaseStringUTFChars(cacheFile, cCache);
        const char* cMem = env->GetStringUTFChars(memoryMode, nullptr);
        env->ReleaseStringUTFChars(memoryMode, cMem);
        const char* cPow = env->GetStringUTFChars(powerMode, nullptr);
        env->ReleaseStringUTFChars(powerMode, cPow);

        return env->NewStringUTF(json.str().c_str());
    } catch (const std::exception& e) {
        std::string err = std::string("MNN PROFILE ERROR: ") + e.what();
        env->ReleaseStringUTFChars(modelPath, cModel);
        env->ReleaseStringUTFChars(backend, cBackend);
        env->ReleaseStringUTFChars(backupType, cBackup);
        const char* cCacheErr = cacheFile ? env->GetStringUTFChars(cacheFile, nullptr) : nullptr;
        if (cCacheErr) env->ReleaseStringUTFChars(cacheFile, cCacheErr);
        const char* cMem = env->GetStringUTFChars(memoryMode, nullptr);
        env->ReleaseStringUTFChars(memoryMode, cMem);
        const char* cPow = env->GetStringUTFChars(powerMode, nullptr);
        env->ReleaseStringUTFChars(powerMode, cPow);
        return env->NewStringUTF(err.c_str());
    }
#else
    env->ReleaseStringUTFChars(backupType, cBackup);
    const char* cMem = env->GetStringUTFChars(memoryMode, nullptr);
    env->ReleaseStringUTFChars(memoryMode, cMem);
    const char* cPow = env->GetStringUTFChars(powerMode, nullptr);
    env->ReleaseStringUTFChars(powerMode, cPow);
    const char* cFill = env->GetStringUTFChars(inputFill, nullptr);
    env->ReleaseStringUTFChars(inputFill, cFill);
    std::ostringstream msg;
    msg << "MNN not bundled. Cannot profile. Place headers and libMNN.so as documented.";
    env->ReleaseStringUTFChars(modelPath, cModel);
    env->ReleaseStringUTFChars(backend, cBackend);
    return env->NewStringUTF(msg.str().c_str());
#endif
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_mnn_runner_mnn_1runner_1app_NativeBridge_getModelInfo(
        JNIEnv* env,
        jobject /* this */,
        jstring modelPath) {
    const char* cModel = env->GetStringUTFChars(modelPath, nullptr);
#if HAVE_MNN
    try {
        std::unique_ptr<MNN::Interpreter> net(MNN::Interpreter::createFromFile(cModel));
        if (!net) throw std::runtime_error("Failed to create interpreter");
        MNN::ScheduleConfig cfg;
        cfg.type = MNN_FORWARD_CPU;
        auto session = net->createSession(cfg);
        if (!session) throw std::runtime_error("Failed to create session");

        auto inputs = net->getSessionInputAll(session);
        std::ostringstream json;
        json << "{\"inputs\":[";
        bool first = true;
        for (auto& kv : inputs) {
            auto* t = kv.second;
            if (!t) continue;
            if (!first) json << ",";
            first = false;
            json << "{\"name\":\"" << kv.first << "\",\"dims\":[";
            for (int i = 0; i < t->dimensions(); ++i) {
                json << t->length(i);
                if (i + 1 < t->dimensions()) json << ",";
            }
            json << "],\"dtype\":\"";
            switch (t->getType().code) {
                case halide_type_float: json << "float"; break;
                case halide_type_int: json << "int"; break;
                case halide_type_uint: json << "uint"; break;
                default: json << "unknown"; break;
            }
            json << "\"}";
        }
        json << "]}";

        net->releaseSession(session);
        env->ReleaseStringUTFChars(modelPath, cModel);
        return env->NewStringUTF(json.str().c_str());
    } catch (const std::exception& e) {
        std::string err = std::string("{\"error\":\"") + e.what() + "\"}";
        env->ReleaseStringUTFChars(modelPath, cModel);
        return env->NewStringUTF(err.c_str());
    }
#else
    std::ostringstream msg;
    msg << "{\"error\":\"MNN not bundled. Place headers under src/main/cpp/third_party/MNN/include and libMNN.so under src/main/jniLibs/<ABI>/\"}";
    env->ReleaseStringUTFChars(modelPath, cModel);
    return env->NewStringUTF(msg.str().c_str());
#endif
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_mnn_runner_mnn_1runner_1app_NativeBridge_runModelMulti(
        JNIEnv* env,
        jobject /* this */,
        jstring modelPath,
        jobjectArray inputNames,
        jobjectArray inputShapes,
        jstring backend,
        jstring backupType,
        jstring memoryMode,
        jstring precisionMode,
        jstring powerMode,
        jstring inputFill,
        jint threads,
        jstring cacheFile) {
    const char* cModel = env->GetStringUTFChars(modelPath, nullptr);
    const char* cBackend = env->GetStringUTFChars(backend, nullptr);
    const char* cBackup = env->GetStringUTFChars(backupType, nullptr);

#if HAVE_MNN
    try {
        std::unique_ptr<MNN::Interpreter> net(MNN::Interpreter::createFromFile(cModel));
        if (!net) throw std::runtime_error("Failed to create interpreter");

        // Optional cache file
        const char* cCache = cacheFile ? env->GetStringUTFChars(cacheFile, nullptr) : nullptr;
        if (cCache && std::strlen(cCache) > 0) {
            net->setCacheFile(cCache);
        }

        MNN::ScheduleConfig cfg;
        cfg.type = (MNNForwardType)mapForward(cBackend);
        cfg.backupType = (MNNForwardType)mapForward(std::string(cBackup ? cBackup : "CPU"));
        cfg.numThread = threads > 0 ? threads : 1;

        MNN::BackendConfig bcfg;
        const char* cPrec = env->GetStringUTFChars(precisionMode, nullptr);
        std::string prec = cPrec ? std::string(cPrec) : std::string("NORMAL");
        if (prec == "LOW") bcfg.precision = MNN::BackendConfig::Precision_Low;
        else if (prec == "HIGH") bcfg.precision = MNN::BackendConfig::Precision_High;
        else bcfg.precision = MNN::BackendConfig::Precision_Normal;
        env->ReleaseStringUTFChars(precisionMode, cPrec);
        cfg.backendConfig = &bcfg;

        auto session = net->createSession(cfg);
        if (!session) throw std::runtime_error("Failed to create session");

        // Build name -> shape map from Java arrays
        jsize nInputs = env->GetArrayLength(inputNames);
        jsize nShapes = env->GetArrayLength(inputShapes);
        if (nInputs != nShapes) throw std::runtime_error("names/shapes length mismatch");

        for (jsize i = 0; i < nInputs; ++i) {
            auto jname = (jstring)env->GetObjectArrayElement(inputNames, i);
            const char* cname = env->GetStringUTFChars(jname, nullptr);
            auto jshape = (jintArray)env->GetObjectArrayElement(inputShapes, i);
            jsize slen = env->GetArrayLength(jshape);
            std::vector<int> shape(slen);
            env->GetIntArrayRegion(jshape, 0, slen, shape.data());

            auto* in = net->getSessionInput(session, cname);
            if (in) {
                net->resizeTensor(in, shape);
            }

            env->ReleaseStringUTFChars(jname, cname);
            env->DeleteLocalRef(jname);
            env->DeleteLocalRef(jshape);
        }
        net->resizeSession(session);

        // Fill mode
        std::string fill = "ZERO";
        const char* cFill = env->GetStringUTFChars(inputFill, nullptr);
        if (cFill) fill = std::string(cFill);
        env->ReleaseStringUTFChars(inputFill, cFill);

        std::mt19937 rng(42);
        std::uniform_real_distribution<float> uni(0.0f, 1.0f);
        std::normal_distribution<float> norm(0.0f, 1.0f);

        auto inputsAll = net->getSessionInputAll(session);
        for (auto& kv : inputsAll) {
            auto* in = kv.second;
            if (!in) continue;
            auto host = std::make_shared<MNN::Tensor>(in, in->getDimensionType());
            auto bytes = host->size();
            auto code = host->getType().code;
            if (fill == "ONE" && code == halide_type_float) {
                float* ptr = host->host<float>();
                for (int i = 0; i < host->elementSize(); ++i) ptr[i] = 1.0f;
            } else if (fill == "UNIFORM" && code == halide_type_float) {
                float* ptr = host->host<float>();
                for (int i = 0; i < host->elementSize(); ++i) ptr[i] = uni(rng);
            } else if (fill == "NORMAL" && code == halide_type_float) {
                float* ptr = host->host<float>();
                for (int i = 0; i < host->elementSize(); ++i) ptr[i] = norm(rng);
            } else {
                std::memset(host->host<void>(), 0, bytes);
            }
            in->copyFromHostTensor(host.get());
        }

        net->runSession(session);

        auto outputs = net->getSessionOutputAll(session);
        std::ostringstream out;
        bool first = true;
        for (auto& kv : outputs) {
            auto* t = kv.second;
            if (!t) continue;
            if (!first) out << ", ";
            first = false;
            out << kv.first << "[";
            for (int i = 0; i < t->dimensions(); ++i) {
                out << t->length(i);
                if (i + 1 < t->dimensions()) out << "x";
            }
            out << "]";
        }

        net->releaseSession(session);

        std::ostringstream msg;
        msg << "MNN 3.1.0 OK backend=" << cBackend << " outputs=" << out.str();

        env->ReleaseStringUTFChars(modelPath, cModel);
        env->ReleaseStringUTFChars(backend, cBackend);
        env->ReleaseStringUTFChars(backupType, cBackup);
        if (cCache) env->ReleaseStringUTFChars(cacheFile, cCache);
        const char* cMem = env->GetStringUTFChars(memoryMode, nullptr);
        env->ReleaseStringUTFChars(memoryMode, cMem);
        const char* cPow = env->GetStringUTFChars(powerMode, nullptr);
        env->ReleaseStringUTFChars(powerMode, cPow);

        return env->NewStringUTF(msg.str().c_str());
    } catch (const std::exception& e) {
        std::string err = std::string("MNN ERROR: ") + e.what();
        env->ReleaseStringUTFChars(modelPath, cModel);
        env->ReleaseStringUTFChars(backend, cBackend);
        env->ReleaseStringUTFChars(backupType, cBackup);
        const char* cCacheErr = cacheFile ? env->GetStringUTFChars(cacheFile, nullptr) : nullptr;
        if (cCacheErr) env->ReleaseStringUTFChars(cacheFile, cCacheErr);
        const char* cMem = env->GetStringUTFChars(memoryMode, nullptr);
        env->ReleaseStringUTFChars(memoryMode, cMem);
        const char* cPow = env->GetStringUTFChars(powerMode, nullptr);
        env->ReleaseStringUTFChars(powerMode, cPow);
        return env->NewStringUTF(err.c_str());
    }
#else
    // Stub when MNN is unavailable
    env->ReleaseStringUTFChars(backend, cBackend);
    env->ReleaseStringUTFChars(backupType, cBackup);
    const char* cMem = env->GetStringUTFChars(memoryMode, nullptr);
    env->ReleaseStringUTFChars(memoryMode, cMem);
    const char* cPow = env->GetStringUTFChars(powerMode, nullptr);
    env->ReleaseStringUTFChars(powerMode, cPow);
    const char* cFill = env->GetStringUTFChars(inputFill, nullptr);
    env->ReleaseStringUTFChars(inputFill, cFill);
    const char* cCache = cacheFile ? env->GetStringUTFChars(cacheFile, nullptr) : nullptr;
    if (cCache) env->ReleaseStringUTFChars(cacheFile, cCache);
    std::ostringstream msg;
    msg << "MNN not bundled. Place headers under src/main/cpp/third_party/MNN/include and libMNN.so under src/main/jniLibs/<ABI>/";
    env->ReleaseStringUTFChars(modelPath, cModel);
    return env->NewStringUTF(msg.str().c_str());
#endif
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_mnn_runner_mnn_1runner_1app_NativeBridge_runModelMultiProfile(
        JNIEnv* env,
        jobject /* this */,
        jstring modelPath,
        jobjectArray inputNames,
        jobjectArray inputShapes,
        jstring backend,
        jstring backupType,
        jstring memoryMode,
        jstring precisionMode,
        jstring powerMode,
        jstring inputFill,
        jint threads,
        jstring cacheFile) {
    const char* cModel = env->GetStringUTFChars(modelPath, nullptr);
    const char* cBackend = env->GetStringUTFChars(backend, nullptr);
    const char* cBackup = env->GetStringUTFChars(backupType, nullptr);

#if HAVE_MNN
    using clock = std::chrono::steady_clock;
    auto t0 = clock::now();
    std::ostringstream report;
    try {
        std::unique_ptr<MNN::Interpreter> net(MNN::Interpreter::createFromFile(cModel));
        if (!net) throw std::runtime_error("Failed to create interpreter");
        auto t1 = clock::now();

        // Optional cache file
        const char* cCache = cacheFile ? env->GetStringUTFChars(cacheFile, nullptr) : nullptr;
        if (cCache && std::strlen(cCache) > 0) {
            net->setCacheFile(cCache);
        }

        MNN::ScheduleConfig cfg;
        cfg.type = (MNNForwardType)mapForward(cBackend);
        cfg.backupType = (MNNForwardType)mapForward(std::string(cBackup ? cBackup : "CPU"));
        cfg.numThread = threads > 0 ? threads : 1;

        MNN::BackendConfig bcfg;
        const char* cPrec = env->GetStringUTFChars(precisionMode, nullptr);
        std::string prec = cPrec ? std::string(cPrec) : std::string("NORMAL");
        if (prec == "LOW") bcfg.precision = MNN::BackendConfig::Precision_Low;
        else if (prec == "HIGH") bcfg.precision = MNN::BackendConfig::Precision_High;
        else bcfg.precision = MNN::BackendConfig::Precision_Normal;
        env->ReleaseStringUTFChars(precisionMode, cPrec);
        cfg.backendConfig = &bcfg;

        auto t2_before = clock::now();
        auto session = net->createSession(cfg);
        if (!session) throw std::runtime_error("Failed to create session");
        auto t2 = clock::now();

        // Set per-input shapes
        jsize nInputs = env->GetArrayLength(inputNames);
        jsize nShapes = env->GetArrayLength(inputShapes);
        if (nInputs != nShapes) throw std::runtime_error("names/shapes length mismatch");
        for (jsize i = 0; i < nInputs; ++i) {
            auto jname = (jstring)env->GetObjectArrayElement(inputNames, i);
            const char* cname = env->GetStringUTFChars(jname, nullptr);
            auto jshape = (jintArray)env->GetObjectArrayElement(inputShapes, i);
            jsize slen = env->GetArrayLength(jshape);
            std::vector<int> shape(slen);
            env->GetIntArrayRegion(jshape, 0, slen, shape.data());
            auto* in = net->getSessionInput(session, cname);
            if (in) {
                net->resizeTensor(in, shape);
            }
            env->ReleaseStringUTFChars(jname, cname);
            env->DeleteLocalRef(jname);
            env->DeleteLocalRef(jshape);
        }
        auto t3_before = clock::now();
        net->resizeSession(session);
        auto t3 = clock::now();

        // Fill mode
        std::string fill = "ZERO";
        const char* cFill = env->GetStringUTFChars(inputFill, nullptr);
        if (cFill) fill = std::string(cFill);
        env->ReleaseStringUTFChars(inputFill, cFill);
        std::mt19937 rng(42);
        std::uniform_real_distribution<float> uni(0.0f, 1.0f);
        std::normal_distribution<float> norm(0.0f, 1.0f);

        auto inputsAll = net->getSessionInputAll(session);
        for (auto& kv : inputsAll) {
            auto* in = kv.second;
            if (!in) continue;
            auto host = std::make_shared<MNN::Tensor>(in, in->getDimensionType());
            auto bytes = host->size();
            auto code = host->getType().code;
            if (fill == "ONE" && code == halide_type_float) {
                float* ptr = host->host<float>();
                for (int i = 0; i < host->elementSize(); ++i) ptr[i] = 1.0f;
            } else if (fill == "UNIFORM" && code == halide_type_float) {
                float* ptr = host->host<float>();
                for (int i = 0; i < host->elementSize(); ++i) ptr[i] = uni(rng);
            } else if (fill == "NORMAL" && code == halide_type_float) {
                float* ptr = host->host<float>();
                for (int i = 0; i < host->elementSize(); ++i) ptr[i] = norm(rng);
            } else {
                std::memset(host->host<void>(), 0, bytes);
            }
            in->copyFromHostTensor(host.get());
        }

        using clock = std::chrono::steady_clock;
        auto dur_ms = [](clock::time_point a, clock::time_point b) {
            return std::chrono::duration_cast<std::chrono::duration<double, std::milli>>(b - a).count();
        };
        int threadsInfo = cfg.numThread;
        (void)net->getSessionInfo(session, MNN::Interpreter::THREAD_NUMBER, &threadsInfo);
        int beBuf[16] = {0};
        bool hasBE = net->getSessionInfo(session, MNN::Interpreter::BACKENDS, beBuf);

        struct OpPerf { std::string name; std::string type; double ms = 0.0; double start = 0.0; double end = 0.0; uint64_t deviceId = 0; std::string backend; };
        std::vector<OpPerf> ops;
        std::map<const MNN::OperatorInfo*, clock::time_point> startByPtr;

        auto pickGpuLabel = [&](int primaryType) -> const char* {
            auto isGpu = [](int t) {
                return t == (int)MNN_FORWARD_OPENCL || t == (int)MNN_FORWARD_OPENGL ||
                       t == (int)MNN_FORWARD_VULKAN || t == (int)MNN_FORWARD_CUDA ||
                       t == (int)MNN_FORWARD_METAL || t == (int)MNN_FORWARD_NN;
            };
            if (primaryType == (int)MNN_FORWARD_AUTO || primaryType == (int)MNN_FORWARD_CPU) {
                if (hasBE) {
                    for (int i = 0; i < 16; ++i) {
                        int v = beBuf[i];
                        if (v == 0 && i > 0) break;
                        if (v < 0 || v > 20) continue;
                        if (isGpu(v)) return forwardName((MNNForwardType)v);
                    }
                }
                return "CPU";
            }
            if (isGpu(primaryType)) return forwardName((MNNForwardType)primaryType);
            return "CPU";
        };
        const int primaryType = mapForward(cBackend);
        const char* gpuLabel = pickGpuLabel(primaryType);

        clock::time_point runStartAnchor; // set before run
        auto before = [&](const std::vector<MNN::Tensor*>& tensors, const MNN::OperatorInfo* info) {
            (void)tensors;
            startByPtr[info] = clock::now();
            return true;
        };
        auto after = [&](const std::vector<MNN::Tensor*>& tensors, const MNN::OperatorInfo* info) {
            auto tEnd = clock::now();
            OpPerf rec;
            rec.name = info ? info->name() : std::string("op");
            rec.type = info ? info->type() : std::string("unknown");
            auto it = startByPtr.find(info);
            if (it != startByPtr.end()) {
                rec.ms = dur_ms(it->second, tEnd);
                rec.start = dur_ms(runStartAnchor, it->second);
                rec.end = dur_ms(runStartAnchor, tEnd);
            }
            if (!tensors.empty() && tensors[0]) {
                rec.deviceId = tensors[0]->deviceId();
            }
            rec.backend = rec.deviceId ? std::string(gpuLabel) : std::string("CPU");
            ops.emplace_back(std::move(rec));
            return true;
        };
        runStartAnchor = clock::now();
        // High-level run only (no per-op callbacks)
        net->runSession(session);
        auto t4 = clock::now();

        auto outputs = net->getSessionOutputAll(session);
        std::ostringstream outShapes;
        bool first = true;
        for (auto& kv : outputs) {
            auto* t = kv.second;
            if (!t) continue;
            if (!first) outShapes << ", ";
            first = false;
            outShapes << kv.first << "[";
            for (int i = 0; i < t->dimensions(); ++i) {
                outShapes << t->length(i);
                if (i + 1 < t->dimensions()) outShapes << "x";
            }
            outShapes << "]";
        }

        // Build JSON report
        std::ostringstream json;
        json.setf(std::ios::fixed); json.precision(3);
        json << "{";
        json << "\"profile\":true,";
        json << "\"backend\":\"" << forwardName((MNNForwardType)mapForward(cBackend)) << "\",";
        json << "\"backup\":\"" << forwardName((MNNForwardType)mapForward(std::string(cBackup ? cBackup : "CPU"))) << "\",";
        json << "\"threads\":" << threadsInfo << ",";
        json << "\"metrics\":{"
             << "\"createInterpreter_ms\":" << dur_ms(t0, t1) << ","
             << "\"createSession_ms\":" << dur_ms(t2_before, t2) << ","
             << "\"resizeSession_ms\":" << dur_ms(t3_before, t3) << ","
             << "\"runSession_ms\":" << dur_ms(runStartAnchor, t4) << "},";
        json << "\"outputs\":[";
        {
            bool f = true;
            for (auto& kv : outputs) {
                auto* t = kv.second; if (!t) continue;
                if (!f) json << ","; f = false;
                json << "{\"name\":\"" << kv.first << "\",\"shape\":[";
                for (int i = 0; i < t->dimensions(); ++i) {
                    if (i) json << ",";
                    json << t->length(i);
                }
                json << "]}";
            }
        }
        json << "],";
        json << "\"ops\":[";
        for (size_t i = 0; i < ops.size(); ++i) {
            const auto& op = ops[i];
            if (i) json << ",";
            json << "{\"index\":" << (i+1)
                 << ",\"type\":\"" << op.type << "\""
                 << ",\"name\":\"" << op.name << "\""
                 << ",\"backend\":\"" << op.backend << "\""
                 << ",\"start_ms\":" << op.start
                 << ",\"end_ms\":" << op.end
                 << ",\"duration_ms\":" << op.ms
                 << "}";
        }
        json << "]}";

        net->releaseSession(session);

        env->ReleaseStringUTFChars(modelPath, cModel);
        env->ReleaseStringUTFChars(backend, cBackend);
        env->ReleaseStringUTFChars(backupType, cBackup);
        if (cCache) env->ReleaseStringUTFChars(cacheFile, cCache);
        const char* cMem = env->GetStringUTFChars(memoryMode, nullptr);
        env->ReleaseStringUTFChars(memoryMode, cMem);
        const char* cPow = env->GetStringUTFChars(powerMode, nullptr);
        env->ReleaseStringUTFChars(powerMode, cPow);
        return env->NewStringUTF(json.str().c_str());
    } catch (const std::exception& e) {
        std::string err = std::string("MNN PROFILE ERROR: ") + e.what();
        env->ReleaseStringUTFChars(modelPath, cModel);
        env->ReleaseStringUTFChars(backend, cBackend);
        env->ReleaseStringUTFChars(backupType, cBackup);
        const char* cMem = env->GetStringUTFChars(memoryMode, nullptr);
        env->ReleaseStringUTFChars(memoryMode, cMem);
        const char* cPow = env->GetStringUTFChars(powerMode, nullptr);
        env->ReleaseStringUTFChars(powerMode, cPow);
        return env->NewStringUTF(err.c_str());
    }
#else
    env->ReleaseStringUTFChars(backend, cBackend);
    env->ReleaseStringUTFChars(backupType, cBackup);
    const char* cMem = env->GetStringUTFChars(memoryMode, nullptr);
    env->ReleaseStringUTFChars(memoryMode, cMem);
    const char* cPow = env->GetStringUTFChars(powerMode, nullptr);
    env->ReleaseStringUTFChars(powerMode, cPow);
    const char* cFill = env->GetStringUTFChars(inputFill, nullptr);
    env->ReleaseStringUTFChars(inputFill, cFill);
    const char* cCache2 = cacheFile ? env->GetStringUTFChars(cacheFile, nullptr) : nullptr;
    if (cCache2) env->ReleaseStringUTFChars(cacheFile, cCache2);
    std::ostringstream msg;
    msg << "MNN not bundled. Cannot profile. Place headers and libMNN.so as documented.";
    env->ReleaseStringUTFChars(modelPath, cModel);
    return env->NewStringUTF(msg.str().c_str());
#endif
}
