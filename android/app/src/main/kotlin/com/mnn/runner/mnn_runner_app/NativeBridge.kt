package com.mnn.runner.mnn_runner_app

import android.util.Log
import java.io.File

object NativeBridge {
    init {
        try {
            System.loadLibrary("mnn_runner")
        } catch (t: Throwable) {
            // Log the error to aid diagnosing missing native deps.
            Log.e("NativeBridge", "Failed to load native library 'mnn_runner'", t)
        }
    }

    private fun tryLoadLibrary(name: String): Boolean = try {
        System.loadLibrary(name); true
    } catch (_: Throwable) { false }

    /**
     * Lazily load optional MNN backend plugin libraries based on the requested backends.
     * This avoids loading backends (e.g., OpenCL) on devices where the dependency chain
     * is not accessible, which would spam linker warnings and fall back anyway.
     */
    @JvmStatic
    fun ensureBackendLibs(primary: String?, backup: String?) {
        val p = primary?.uppercase()
        val b = backup?.uppercase()
        // Do NOT attempt to load MNN_Express here.
        // Many devices have a system-wide libMNN_Express.so which is not accessible
        // to app namespaces on Android P+. Trying to load it when not packaged
        // causes noisy linker warnings. If you need Express, ship libMNN_Express.so
        // under jniLibs/<ABI>/ and load it explicitly at that time.
        if (p == "VULKAN" || b == "VULKAN") {
            // Load packaged Vulkan plugin, best-effort
            tryLoadLibrary("MNN_Vulkan")
            // Preload system vulkan loader to fail early if missing
            tryLoadLibrary("vulkan")
        }
        if (p == "OPENCL" || b == "OPENCL") {
            // Load packaged OpenCL plugin only (no libOpenCL preload).
            // The plugin itself will dlopen any vendor OpenCL driver at runtime if needed.
            tryLoadLibrary("MNN_CL")
        }
        if (p == "OPENGL" || b == "OPENGL") {
            tryLoadLibrary("MNN_GL")
        }
    }

    /**
     * Check if Vulkan runtime and MNN Vulkan plugin can be loaded in this process.
     * This intentionally only checks dlopen/loadLibrary feasibility and avoids creating instances.
     */
    @JvmStatic
    fun hasVulkanRuntime(): Boolean {
        val vk = tryLoadLibrary("vulkan")
        val plugin = tryLoadLibrary("MNN_Vulkan")
        return vk && plugin
    }

    /**
     * Probe availability of CPU/VULKAN/OPENCL backends and return a JSON string.
     * Example: {"cpu":{"available":true},"vulkan":{"available":true,"lib":true,"plugin":true},"opencl":{"available":false,"lib":false,"plugin":false,"source":null}}
     */
    @JvmStatic
    fun probeBackends(): String {
        val cpuAvail = true

        // Vulkan probe: require both system loader and packaged plugin to be present
        val vkAvail = hasVulkanRuntime()

        // OpenCL probe: Try loading libMNN_CL.so only. We do NOT load vendor libOpenCL.so here.
        // Modern MNN CL builds don't link against libOpenCL at load time and will dlopen
        // the driver on first use. If your libMNN_CL.so was built otherwise, loading may fail.
        val clPlugin = tryLoadLibrary("MNN_CL")
        val clAvail = clPlugin

        val sb = StringBuilder(160)
        sb.append('{')
        sb.append("\"cpu\":{\"available\":true}")
        sb.append(',')
        sb.append("\"vulkan\":{")
            .append("\"available\":").append(if (vkAvail) "true" else "false").append(',')
            .append("\"lib\":").append(if (vkAvail) "true" else "false").append(',')
            .append("\"plugin\":").append(if (vkAvail) "true" else "false").append(',')
            .append("\"source\":\"apk\"")
            .append('}')
        sb.append(',')
        sb.append("\"opencl\":{")
            .append("\"available\":").append(if (clAvail) "true" else "false").append(',')
            .append("\"lib\":").append(if (clPlugin) "true" else "false").append(',')
            .append("\"plugin\":").append(if (clPlugin) "true" else "false").append(',')
            .append("\"source\":").append(if (clPlugin) "\"apk\"" else "null").append('}')
        sb.append('}')
        return sb.toString()
    }

    external fun runModel(
        modelPath: String,
        inputShape: IntArray,
        backend: String,
        backupType: String,
        memoryMode: String,
        precisionMode: String,
        powerMode: String,
        inputFill: String,
        threads: Int,
        cacheFile: String?
    ): String

    external fun getModelInfo(
        modelPath: String
    ): String

    // Profiled single-input run
    external fun runModelProfile(
        modelPath: String,
        inputShape: IntArray,
        backend: String,
        backupType: String,
        memoryMode: String,
        precisionMode: String,
        powerMode: String,
        inputFill: String,
        threads: Int,
        cacheFile: String?
    ): String

    // Profiled multi-input run
    external fun runModelMultiProfile(
        modelPath: String,
        inputNames: Array<String>,
        inputShapes: Array<IntArray>,
        backend: String,
        backupType: String,
        memoryMode: String,
        precisionMode: String,
        powerMode: String,
        inputFill: String,
        threads: Int,
        cacheFile: String?
    ): String

    external fun runModelMulti(
        modelPath: String,
        inputNames: Array<String>,
        inputShapes: Array<IntArray>,
        backend: String,
        backupType: String,
        memoryMode: String,
        precisionMode: String,
        powerMode: String,
        inputFill: String,
        threads: Int,
        cacheFile: String?
    ): String
}
