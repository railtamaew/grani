package com.granivpn.mobile

/**
 * Убирает из строк, попадающих в logcat, типичные секреты Xray/VLESS (UUID, ключи).
 * Не заменяет полноценный парсер JSON — достаточно для диагностических превью.
 */
object VpnLogRedaction {
    private val uuidRegex = Regex(
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        RegexOption.IGNORE_CASE,
    )

    private val quotedSensitiveKey = Regex(
        "\"(publicKey|privateKey|password|pbk|shortId)\"\\s*:\\s*\"[^\"]*\"",
        RegexOption.IGNORE_CASE,
    )

    fun redactSensitiveJson(text: String): String {
        var s = quotedSensitiveKey.replace(text) { m ->
            "\"${m.groupValues[1]}\":\"<redacted>\""
        }
        s = uuidRegex.replace(s) { "<redacted>" }
        return s
    }

    fun previewRedacted(text: String, maxLen: Int): String {
        val r = redactSensitiveJson(text)
        return if (r.length <= maxLen) r else r.take(maxLen) + "…"
    }

    fun describeMethodCall(method: String, arguments: Any?): String {
        return when (method) {
            "connect" -> describeConnectArgs(arguments)
            else -> {
                val suffix = when (arguments) {
                    is Map<*, *> -> "keys=[${arguments.keys.joinToString(",")}]"
                    null -> "args=null"
                    else -> "argsType=${arguments.javaClass.simpleName}"
                }
                "method=$method $suffix"
            }
        }
    }

    private fun describeConnectArgs(arguments: Any?): String {
        if (arguments !is Map<*, *>) {
            return "method=connect argsType=${arguments?.javaClass?.simpleName ?: "null"}"
        }
        val keys = arguments.keys.joinToString(",")
        val config = arguments["config"] as? String
        val configLen = config?.length ?: 0
        return "method=connect keys=[$keys] config_len=$configLen"
    }
}
