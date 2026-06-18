package com.granivpn.mobile

import org.junit.Ignore
import org.junit.Test

/**
 * Placeholder: [com.wireguard.config.Config] is not on the app module unit-test classpath.
 * Re-enable when wireguard tunnel is added as testImplementation.
 */
@Ignore("WireGuard Config not on unit-test classpath")
class WireGuardConfigParseTest {

    @Test
    fun parse_valid_config() {
        // Example config text for future Config.parse(BufferedReader(StringReader(...))):
        // [Interface] PrivateKey = ... Address = 10.0.0.2/32 ...
        // [Peer] PublicKey = ... Endpoint = ...
    }
}
