package com.bluebubbles.messaging.services.rustpush

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler

/**
 * Observes only the device's default network. Android Auto's local Wi-Fi Direct
 * link must not be treated as an Internet route for Apple Push Services.
 */
internal data class AppleNetworkSnapshot(
    val network: Network?,
    val hasInternet: Boolean,
    val validated: Boolean,
) {
    val eligibleForApplePush: Boolean
        get() = hasInternet && validated
}

internal class AppleNetworkMonitor(
    context: Context,
    private val handler: Handler,
    private val onChange: (AppleNetworkSnapshot) -> Unit,
) {
    private val connectivityManager =
        context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private var registered = false
    private var lastSnapshot: AppleNetworkSnapshot? = null

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            publishLater(network)
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            publishLater(network)
        }

        override fun onLost(network: Network) {
            handler.post {
                if (registered && lastSnapshot?.network == network) {
                    publish(null)
                }
            }
        }
    }

    fun start() {
        if (registered) return
        registered = true
        connectivityManager.registerDefaultNetworkCallback(callback)
    }

    fun stop() {
        if (!registered) return
        registered = false
        connectivityManager.unregisterNetworkCallback(callback)
        lastSnapshot = null
    }

    private fun publishLater(network: Network) {
        handler.post {
            if (registered) publish(network)
        }
    }

    private fun publish(network: Network?) {
        val capabilities = network?.let(connectivityManager::getNetworkCapabilities)
        val snapshot = AppleNetworkSnapshot(
            network = network,
            hasInternet = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true,
            validated = capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true,
        )
        if (snapshot == lastSnapshot) return
        lastSnapshot = snapshot
        onChange(snapshot)
    }
}
