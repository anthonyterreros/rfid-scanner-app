package com.example.test_app

import android.os.Handler
import android.os.Looper
import com.rscja.deviceapi.RFIDWithUHFBLE
import com.rscja.deviceapi.entity.UHFTAGInfo
import com.rscja.deviceapi.interfaces.ConnectionStatus
import com.rscja.deviceapi.interfaces.ConnectionStatusCallback
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val methodChannelName = "vhc77p_uhf/methods"
    private val eventChannelName = "vhc77p_uhf/events"

    private lateinit var uhf: RFIDWithUHFBLE

    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val streaming = AtomicBoolean(false)

    private var sdkConnected = false
    private var currentAddress: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        uhf = RFIDWithUHFBLE.getInstance()
        uhf.init(applicationContext)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            methodChannelName
        ).setMethodCallHandler(this)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            eventChannelName
        ).setStreamHandler(this)
    }

    override fun onDestroy() {
        try {
            streaming.set(false)
            uhf.free()
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "connectReader" -> {
                val address = call.argument<String>("address")
                if (address.isNullOrBlank()) {
                    result.error("INVALID_ADDRESS", "Dirección BLE vacía", null)
                    return
                }

                connectReader(address, result)
            }

            "disconnectReader" -> {
                try {
                    uhf.disconnect()
                    sdkConnected = false
                    result.success(true)
                } catch (e: Exception) {
                    result.error("DISCONNECT_ERROR", e.message, null)
                }
            }

            "isReaderConnected" -> {
                result.success(sdkConnected)
            }

            "startInventory" -> {
                try {
                    if (!sdkConnected) {
                        result.error("NOT_CONNECTED", "El SDK RFID no está conectado al lector", null)
                        return
                    }

                    val ok = uhf.startInventoryTag()
                    result.success(ok)
                } catch (e: Exception) {
                    result.error("START_INVENTORY_ERROR", e.message, null)
                }
            }

            "stopInventory" -> {
                try {
                    val ok = uhf.stopInventory()
                    result.success(ok)
                } catch (e: Exception) {
                    result.error("STOP_INVENTORY_ERROR", e.message, null)
                }
            }

            "readTags" -> {
                try {
                    val tags = uhf.readTagFromBufferList()
                    result.success(toTagList(tags))
                } catch (e: Exception) {
                    result.error("READ_TAGS_ERROR", e.message, null)
                }
            }

            "inventorySingle" -> {
                try {
                    if (!sdkConnected) {
                        result.error("NOT_CONNECTED", "El SDK RFID no está conectado al lector", null)
                        return
                    }

                    val tag = uhf.inventorySingleTag()
                    val list = if (tag != null) listOf(tag) else emptyList()
                    result.success(toTagList(list))
                } catch (e: Exception) {
                    result.error("INVENTORY_SINGLE_ERROR", e.message, null)
                }
            }

            "getBattery" -> {
                try {
                    if (!sdkConnected) {
                        result.error("NOT_CONNECTED", "El SDK RFID no está conectado al lector", null)
                        return
                    }
                    result.success(mapOf("battery" to uhf.battery))
                } catch (e: Exception) {
                    result.error("GET_BATTERY_ERROR", e.message, null)
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun connectReader(address: String, result: MethodChannel.Result) {
        try {
            if (sdkConnected && currentAddress == address) {
                result.success(true)
                return
            }

            currentAddress = address
            sdkConnected = false

            uhf.connect(address, object : ConnectionStatusCallback<Any> {
                override fun getStatus(connectionStatus: ConnectionStatus?, device: Any?) {
                    when (connectionStatus) {
                        ConnectionStatus.CONNECTED -> {
                            sdkConnected = true
                            mainHandler.post { result.success(true) }
                        }

                        ConnectionStatus.DISCONNECTED -> {
                            sdkConnected = false
                        }

                        else -> {}
                    }
                }
            })
        } catch (e: Exception) {
            result.error("CONNECT_READER_ERROR", e.message, null)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        streaming.set(true)

        executor.execute {
            while (streaming.get()) {
                try {
                    if (!sdkConnected) {
                        Thread.sleep(120)
                        continue
                    }

                    val tags = uhf.readTagFromBufferList()
                    val payload = toTagList(tags)

                    if (payload.isNotEmpty()) {
                        mainHandler.post {
                            eventSink?.success(payload)
                        }
                    }

                    Thread.sleep(80)
                } catch (e: Exception) {
                    mainHandler.post {
                        eventSink?.error("STREAM_ERROR", e.message, null)
                    }
                    break
                }
            }
        }
    }

    override fun onCancel(arguments: Any?) {
        streaming.set(false)
        eventSink = null
    }

    private fun toTagList(tags: List<UHFTAGInfo>?): List<Map<String, Any>> {
        if (tags == null) return emptyList()

        return tags.mapNotNull { tag ->
            val epc = tag.epc ?: return@mapNotNull null
            mapOf(
                "epc" to epc,
                "tid" to (tag.tid ?: ""),
                "user" to (tag.user ?: ""),
                "rssi" to (tag.rssi ?: "")
            )
        }
    }
}