package com.bluebubbles.messaging

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.telephony.SmsMessage
import com.bluebubbles.messaging.diagnostics.MessagingDiagnostics
import com.bluebubbles.messaging.services.rustpush.SMSAuthGateway


class SMSReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val extractMessages = Telephony.Sms.Intents.getMessagesFromIntent(intent)

        var totalBody = ""
        for (message in extractMessages) {
            MessagingDiagnostics.event("inbound_classified", transport = "sms", outcome = "received")
            if (message.messageBody.startsWith("~")) continue; // google fi being stupid
            totalBody += message.messageBody
        }
        MessagingDiagnostics.event("registration_response_dispatch", transport = "sms")
        SMSAuthGateway.processMessage(totalBody)
    }
}
