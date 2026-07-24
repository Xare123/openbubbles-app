package com.bluebubbles.messaging

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.SmsMessage
import com.bluebubbles.messaging.diagnostics.MessagingDiagnostics
import com.bluebubbles.messaging.services.rustpush.SMSAuthGateway
import java.nio.charset.StandardCharsets


class PDUReceiver : BroadcastReceiver() {
    private fun sanityCheck(result: String?): Boolean {
        return result != null && result.contains("REG-RESP")
    }

    private fun sanityCheck(message: SmsMessage?): Boolean {
        return message != null && sanityCheck(message.messageBody)
    }

    private fun found(input: String): String {
        val resdata = input.substring(input.indexOf("REG-RESP"))
        MessagingDiagnostics.event("inbound_classified", transport = "sms", outcome = "registration_response")
        return resdata
    }

    private fun parse(pdu: ByteArray): String? {
        try {
            val message = SmsMessage.createFromPdu(pdu, "3gpp")
            if (sanityCheck(message)) {
                return found(message.messageBody)
            }
        } catch (e: Exception) {
            MessagingDiagnostics.failure("inbound_parse", "sms", e)
        }
        try {
            val message = SmsMessage.createFromPdu(pdu, "3gpp2")
            if (sanityCheck(message)) {
                return found(message.messageBody)
            }
        } catch (e: Exception) {
            MessagingDiagnostics.failure("inbound_parse", "sms", e)
        }
        try {
            val pduString = String(pdu, 0, pdu.size, StandardCharsets.US_ASCII)
            if (sanityCheck(pduString)) {
                return found(pduString)
            }
        } catch (e: Exception) {
            MessagingDiagnostics.failure("inbound_parse", "sms", e)
        }
        MessagingDiagnostics.event("inbound_classified", transport = "sms", outcome = "unrecognized")
        return null
    }

    override fun onReceive(context: Context, intent: Intent) {
        //Runs whenever a data SMS PDU is received. On some carriers (i.e. AT&T), the REG-RESP message is sent as
        //  a data SMS (PDU) instead of a regular SMS message.
        MessagingDiagnostics.event("inbound_observer", transport = "sms", outcome = "received")
        val bundle = intent.extras
        if (bundle != null) {
            val pdus = bundle["pdus"] as Array<Any>?
            if (pdus == null) {
                MessagingDiagnostics.event("inbound_observer", transport = "sms", outcome = "missing_pdu")
                return
            }
            for (o in pdus) {
                parse(o as ByteArray)?.let {
                    SMSAuthGateway.processMessage(it)
                }
                //SMSReceiver.processMessage(SmsMessage.createFromPdu((byte[]) pdus[i]));
            }
        }
    }
}
