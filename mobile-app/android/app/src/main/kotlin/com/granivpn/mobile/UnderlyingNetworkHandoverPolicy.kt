package com.granivpn.mobile

/**
 * Protocol-neutral state machine for physical-network handover.
 *
 * Android can report several NOT_VPN networks at once. Seeing another Wi-Fi
 * or cellular network is therefore not evidence that the VPN dataplane must
 * be restarted. The current physical network remains selected while it is
 * viable. Only its loss/unvalidation starts a grace period, followed by a
 * dataplane check on a concrete replacement network.
 */
internal class UnderlyingNetworkHandoverPolicy(
    private val graceMs: Long,
    private val failuresBeforeReconnect: Int = 2,
) {
    init {
        require(graceMs >= 0L)
        require(failuresBeforeReconnect > 0)
    }

    enum class Transport {
        WIFI,
        MOBILE,
        ETHERNET,
        OTHER,
    }

    data class Candidate(
        val id: String,
        val transport: Transport,
        val hasInternet: Boolean,
        val validated: Boolean,
        val suspended: Boolean = false,
    ) {
        val viable: Boolean
            get() = id.isNotBlank() && hasInternet && validated && !suspended
    }

    sealed class Decision {
        data class Initialized(val selected: Candidate?) : Decision()
        data class Stable(val selected: Candidate?) : Decision()
        data class Pending(
            val from: Candidate,
            val replacement: Candidate?,
            val remainingMs: Long,
        ) : Decision()

        data class VerifyDataplane(
            val from: Candidate,
            val replacement: Candidate,
        ) : Decision()

        data class ProbeAgain(
            val from: Candidate,
            val replacement: Candidate,
            val failedProbes: Int,
        ) : Decision()

        data class HandoverSurvived(
            val from: Candidate,
            val replacement: Candidate,
        ) : Decision()

        data class ReconnectRequired(
            val from: Candidate,
            val replacement: Candidate,
            val failedProbes: Int,
        ) : Decision()
    }

    private var selected: Candidate? = null
    private var pendingFrom: Candidate? = null
    private var pendingReplacementId: String? = null
    private var pendingSinceMs: Long? = null
    private var awaitingVerification = false
    private var failedProbes = 0

    @Synchronized
    fun selectedCandidate(): Candidate? = selected

    @Synchronized
    fun evaluate(
        candidates: Collection<Candidate>,
        preferredNetworkId: String?,
        nowMs: Long,
    ): Decision {
        val viableById = candidates
            .asSequence()
            .filter(Candidate::viable)
            .associateBy(Candidate::id)
        val current = selected

        if (current == null) {
            val initial = chooseReplacement(viableById, preferredNetworkId, null)
            selected = initial
            clearPending()
            return Decision.Initialized(initial)
        }

        val refreshedCurrent = viableById[current.id]
        if (refreshedCurrent != null) {
            selected = refreshedCurrent
            clearPending()
            return Decision.Stable(refreshedCurrent)
        }

        val replacement = chooseReplacement(viableById, preferredNetworkId, current.id)
        val replacementId = replacement?.id
        val pendingStartedAt = pendingSinceMs
        if (pendingStartedAt == null || pendingReplacementId != replacementId) {
            pendingFrom = current
            pendingReplacementId = replacementId
            pendingSinceMs = nowMs
            awaitingVerification = false
            failedProbes = 0
            return Decision.Pending(current, replacement, graceMs)
        }

        val elapsed = (nowMs - pendingStartedAt).coerceAtLeast(0L)
        if (replacement == null || elapsed < graceMs || awaitingVerification) {
            return Decision.Pending(
                from = pendingFrom ?: current,
                replacement = replacement,
                remainingMs = (graceMs - elapsed).coerceAtLeast(0L),
            )
        }

        awaitingVerification = true
        return Decision.VerifyDataplane(pendingFrom ?: current, replacement)
    }

    @Synchronized
    fun recordDataplaneProbe(
        replacement: Candidate,
        healthy: Boolean,
    ): Decision {
        val from = pendingFrom ?: selected
            ?: return Decision.Initialized(replacement.takeIf(Candidate::viable))
        if (!awaitingVerification || replacement.id != pendingReplacementId) {
            return Decision.Stable(selected)
        }

        if (healthy) {
            selected = replacement
            clearPending()
            return Decision.HandoverSurvived(from, replacement)
        }

        failedProbes += 1
        return if (failedProbes >= failuresBeforeReconnect) {
            Decision.ReconnectRequired(from, replacement, failedProbes)
        } else {
            Decision.ProbeAgain(from, replacement, failedProbes)
        }
    }

    /**
     * The physical handover can happen while the VPN is still LOCAL_UP. In
     * that state probing is premature; release the in-flight marker without
     * discarding the pending transition so evaluation can retry at COMMITTED.
     */
    @Synchronized
    fun deferDataplaneVerification(replacement: Candidate) {
        if (replacement.id == pendingReplacementId) {
            awaitingVerification = false
        }
    }

    /** Call after the controlled reconnect has taken ownership of the runtime. */
    @Synchronized
    fun acknowledgeReconnect(replacement: Candidate) {
        selected = replacement.takeIf(Candidate::viable)
        clearPending()
    }

    @Synchronized
    fun reset() {
        selected = null
        clearPending()
    }

    private fun chooseReplacement(
        viableById: Map<String, Candidate>,
        preferredNetworkId: String?,
        excludedId: String?,
    ): Candidate? {
        if (!preferredNetworkId.isNullOrBlank() && preferredNetworkId != excludedId) {
            viableById[preferredNetworkId]?.let { return it }
        }
        return viableById.values
            .asSequence()
            .filter { it.id != excludedId }
            .sortedWith(
                compareBy<Candidate> { transportPriority(it.transport) }
                    .thenBy(Candidate::id),
            )
            .firstOrNull()
    }

    private fun transportPriority(transport: Transport): Int = when (transport) {
        Transport.ETHERNET -> 0
        Transport.WIFI -> 1
        Transport.MOBILE -> 2
        Transport.OTHER -> 3
    }

    private fun clearPending() {
        pendingFrom = null
        pendingReplacementId = null
        pendingSinceMs = null
        awaitingVerification = false
        failedProbes = 0
    }
}
