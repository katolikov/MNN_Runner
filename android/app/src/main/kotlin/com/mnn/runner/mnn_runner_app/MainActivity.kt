package com.mnn.runner.mnn_runner_app

import android.Manifest
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.nio.IntBuffer
// Using our own JNI bridge with MNN 3.1.0 native libs

class MainActivity : FlutterActivity() {
	private val channelName = "mnn_runner"

	override fun onCreate(savedInstanceState: Bundle?) {
		super.onCreate(savedInstanceState)
		// Request read permission for older devices if needed
		if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
			ActivityCompat.requestPermissions(
				this,
				arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE),
				0
			)
		}
	}

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPackageName" -> {
                        result.success(applicationContext.packageName)
                    }
                    "getModelInfo" -> {
                        try {
                            val modelPath = call.arguments as? String
                            if (modelPath.isNullOrBlank()) {
                                result.error("ARG", "Missing modelPath", null)
                                return@setMethodCallHandler
                            }
                            try {
                                val f = java.io.File(modelPath)
                                if (!f.exists()) {
                                    result.error("MODEL", "Model not found: ${modelPath}", null)
                                    return@setMethodCallHandler
                                }
                            } catch (_: Throwable) {
                                result.error("MODEL", "Model not accessible: ${modelPath}", null)
                                return@setMethodCallHandler
                            }
                            val info = try {
                                NativeBridge.getModelInfo(modelPath)
                            } catch (t: Throwable) {
                                "{\"error\":\"JNI error: ${'$'}{t.message}\"}"
                            }
                            result.success(info)
                        } catch (e: Exception) {
                            result.error("INFO", e.message, null)
                        }
                    }
                    "probeBackends" -> {
                        try {
                            val json = NativeBridge.probeBackends()
                            result.success(json)
                        } catch (e: Exception) {
                            result.error("PROBE", e.message, null)
                        }
                    }
                    "runModel" -> {
                        // Offload heavy JNI work off the platform thread to avoid UI stalls/ANR
                        Thread {
                            try {
                                val json = call.arguments as? String ?: run {
                                    runOnUiThread { result.error("ARG", "Missing JSON config", null) }
                                    return@Thread
                                }
                                val cfg = JSONObject(json)
                                val modelPath = cfg.getString("modelPath")
                                val shapeArr = cfg.getJSONArray("inputShape")
                                val inputShape = IntArray(shapeArr.length()) { i -> shapeArr.getInt(i) }
                                var backend = cfg.optString("backend", "CPU")
                                val memoryMode = cfg.optString("memoryMode", "BALANCED")
                                val precisionMode = cfg.optString("precisionMode", "NORMAL")
                                val powerMode = cfg.optString("powerMode", "NORMAL")
                                val threads = cfg.optInt("threads", 4)
                                val inputFill = cfg.optString("inputFill", "ZERO")
                                val profile = cfg.optBoolean("profile", false)
                                val cacheEnabled = cfg.optBoolean("cache", false)
                                val cachePathArg = cfg.optString("cacheFile", "")
                                val cacheFile: String? = try {
                                    val wantCache = cacheEnabled && (backend.equals("VULKAN", true) || backend.equals("OPENCL", true))
                                    val path = if (cachePathArg.isNotBlank()) cachePathArg else if (wantCache) {
                                        val base = applicationContext.getExternalFilesDir(null) ?: applicationContext.filesDir
                                        val dir = java.io.File(base, "mnn_cache")
                                        if (!dir.exists()) dir.mkdirs()
                                        val modelName = java.io.File(modelPath).nameWithoutExtension
                                        java.io.File(dir, "${modelName}_${backend.uppercase()}.cache").absolutePath
                                    } else null
                                    path
                                } catch (_: Throwable) { null }

                                // Support both backupType and backup_type
                                var backupType = if (cfg.has("backupType")) cfg.optString("backupType", "CPU") else cfg.optString("backup_type", "CPU")

                                // Optionally parse per-input shapes
                                val inputShapesObj = cfg.optJSONObject("inputShapes")
                                // If OPENCL requested, downshift to VULKAN/CPU when OpenCL isn't available to avoid noisy dlopen attempts.
                                if (backend.equals("OPENCL", ignoreCase = true)) {
                                    try {
                                        val probe = JSONObject(NativeBridge.probeBackends())
                                        val opencl = probe.optJSONObject("opencl")
                                        val vulkan = probe.optJSONObject("vulkan")
                                        val clAvail = opencl?.optBoolean("available", false) == true
                                        val vkAvail = vulkan?.optBoolean("available", false) == true
                                        if (!clAvail) backend = if (vkAvail) "VULKAN" else "CPU"
                                    } catch (_: Throwable) { backend = "CPU" }
                                }
                                if (backupType.equals("OPENCL", ignoreCase = true)) {
                                    try {
                                        val probe = JSONObject(NativeBridge.probeBackends())
                                        val opencl = probe.optJSONObject("opencl")
                                        val vulkan = probe.optJSONObject("vulkan")
                                        val clAvail = opencl?.optBoolean("available", false) == true
                                        val vkAvail = vulkan?.optBoolean("available", false) == true
                                        if (!clAvail) backupType = if (vkAvail) "VULKAN" else "CPU"
                                    } catch (_: Throwable) { backupType = "CPU" }
                                }

                                // Ensure model exists before JNI call
                                try {
                                    val f = java.io.File(modelPath)
                                    if (!f.exists()) {
                                        runOnUiThread { result.error("MODEL", "Model not found: ${modelPath}", null) }
                                        return@Thread
                                    }
                                } catch (_: Throwable) {
                                    runOnUiThread { result.error("MODEL", "Model not accessible: ${modelPath}", null) }
                                    return@Thread
                                }

                                // Load optional backend plugin libs just-in-time
                                NativeBridge.ensureBackendLibs(backend, backupType)
                                // Guard: if Vulkan requested but runtime not fully available, fall back early
                                if (backend.equals("VULKAN", true) && !NativeBridge.hasVulkanRuntime()) {
                                    // Prefer OpenCL fallback when available; otherwise use backupType or CPU
                                    val probe = try { JSONObject(NativeBridge.probeBackends()) } catch (_: Throwable) { null }
                                    val clAvail = probe?.optJSONObject("opencl")?.optBoolean("available", false) == true
                                    backend = if (clAvail) "OPENCL" else backupType.ifBlank { "CPU" }
                                }

                                val jniMsg = try {
                                    if (inputShapesObj != null && inputShapesObj.length() > 0) {
                                        val names = mutableListOf<String>()
                                        val shapes = mutableListOf<IntArray>()
                                        val it = inputShapesObj.keys()
                                        while (it.hasNext()) {
                                            val name = it.next()
                                            val arr = inputShapesObj.getJSONArray(name)
                                            val shp = IntArray(arr.length()) { i -> arr.getInt(i) }
                                            names.add(name)
                                            shapes.add(shp)
                                        }
                                        if (profile) {
                                            NativeBridge.runModelMultiProfile(
                                                modelPath,
                                                names.toTypedArray(),
                                                shapes.toTypedArray(),
                                                backend,
                                                backupType,
                                                memoryMode,
                                                precisionMode,
                                                powerMode,
                                                inputFill,
                                                threads,
                                                cacheFile
                                            )
                                        } else {
                                            NativeBridge.runModelMulti(
                                                modelPath,
                                                names.toTypedArray(),
                                                shapes.toTypedArray(),
                                                backend,
                                                backupType,
                                                memoryMode,
                                                precisionMode,
                                                powerMode,
                                                inputFill,
                                                threads,
                                                cacheFile
                                            )
                                        }
                                    } else {
                                        if (profile) {
                                            NativeBridge.runModelProfile(
                                                modelPath,
                                                inputShape,
                                                backend,
                                                backupType,
                                                memoryMode,
                                                precisionMode,
                                                powerMode,
                                                inputFill,
                                                threads,
                                                cacheFile
                                            )
                                        } else {
                                            NativeBridge.runModel(
                                                modelPath,
                                                inputShape,
                                                backend,
                                                backupType,
                                                memoryMode,
                                                precisionMode,
                                                powerMode,
                                                inputFill,
                                                threads,
                                                cacheFile
                                            )
                                        }
                                    }
                                } catch (t: Throwable) {
                                    "JNI error: ${'$'}{t.message}"
                                }
                                runOnUiThread { result.success(jniMsg) }
                            } catch (e: Exception) {
                                runOnUiThread { result.error("RUN", e.message, null) }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
