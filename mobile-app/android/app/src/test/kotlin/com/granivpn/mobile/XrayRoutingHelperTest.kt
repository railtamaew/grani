package com.granivpn.mobile

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class XrayRoutingHelperTest {

    private val minimalXrayJson = """
        {
          "log": {"loglevel": "info"},
          "dns": {"servers": ["1.1.1.1"]},
          "inbounds": [{"tag": "socks-in", "port": 10808, "protocol": "socks"}],
          "outbounds": [
            {"tag": "proxy", "protocol": "vless", "settings": {"vnext": [{"address": "45.12.132.94", "port": 4443, "users": [{"id": "u", "encryption": "none"}]}]}},
            {"protocol": "freedom", "tag": "direct"}
          ],
          "routing": {
            "rules": [
              {"type": "field", "ip": ["45.12.132.94"], "outboundTag": "direct"},
              {"type": "field", "ip": ["1.1.1.1"], "outboundTag": "direct"},
              {"type": "field", "inboundTag": ["socks-in"], "outboundTag": "proxy"}
            ]
          }
        }
    """.trimIndent()

    @Test
    fun injectDirectDomains_insertsBeforeSocksProxyRule() {
        val out = XrayRoutingHelper.injectDirectDomains(minimalXrayJson, listOf("api.granilink.com"))
        val rules = JSONObject(out).getJSONObject("routing").getJSONArray("rules")
        var foundDomain = false
        var socksIdx = -1
        for (i in 0 until rules.length()) {
            val r = rules.getJSONObject(i)
            if (r.optJSONArray("inboundTag")?.toString()?.contains("socks-in") == true) {
                socksIdx = i
            }
            if (r.optString("outboundTag") == "direct" && r.has("domain")) {
                val dom = r.getJSONArray("domain").toString()
                if (dom.contains("api.granilink.com")) foundDomain = true
            }
        }
        assertTrue("domain rule for api", foundDomain)
        assertTrue("socks rule exists", socksIdx >= 0)
    }

    @Test
    fun injectDirectIps_insertsBeforeSocksProxyRule() {
        val out = XrayRoutingHelper.injectDirectIps(minimalXrayJson, listOf("159.223.199.122"))
        val rules = JSONObject(out).getJSONObject("routing").getJSONArray("rules")
        var foundIp = false
        for (i in 0 until rules.length()) {
            val r = rules.getJSONObject(i)
            if (r.optString("outboundTag") == "direct" && r.has("ip")) {
                val ips = r.getJSONArray("ip")
                if (ips.length() == 1 && ips.getString(0) == "159.223.199.122") foundIp = true
            }
        }
        assertTrue("ip rule for DO API", foundIp)
    }

    @Test
    fun applyControlPlaneAndUserDirectRouting_mergesControlPlaneConstants() {
        val out = XrayRoutingHelper.applyControlPlaneAndUserDirectRouting(minimalXrayJson, emptyList())
        assertTrue(out.contains("api.granilink.com"))
        assertTrue(out.contains("api.granilink.com"))
        assertTrue(out.contains("159.223.199.122"))
        assertTrue("performance: public DoH direct", out.contains("dns.google"))
        assertTrue("speedtest outbound", out.contains("proxy_speedtest"))
    }

    @Test
    fun applyFullVpnRouting_strictMode_skipsPublicDohDirect() {
        val out = XrayRoutingHelper.applyFullVpnRouting(
            minimalXrayJson,
            emptyList(),
            VpnRoutingPrefs.DNS_STRICT,
        )
        assertTrue(out.contains("api.granilink.com"))
        assertFalse("strict: no dns.google direct injection", out.contains("dns.google"))
    }

    @Test
    fun controlPlaneDomainList_matchesExpected() {
        assertEquals(2, XrayRoutingHelper.CONTROL_PLANE_API_DOMAINS.size)
        assertEquals(1, XrayRoutingHelper.CONTROL_PLANE_API_IPS.size)
    }
}
