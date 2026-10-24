use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const PROTOCOL_VERSION: u8 = 1;
pub const PARTICIPATION_CAPABILITIES: [&str; 4] =
    ["microphone_state", "hand_state", "reaction", "screen_state"];
pub const MAX_MESSAGE_BYTES: usize = 16 * 1024;
const MAX_SDP_BYTES: usize = 12 * 1024;
const MAX_ICE_BYTES: usize = 2 * 1024;

/// El cliente solo elige destinatario y contenido. La identidad de origen
/// siempre se obtiene de la sesión autenticada en el servidor.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClientEnvelope {
    pub version: u8,
    pub event_id: Uuid,
    pub recipient: Uuid,
    pub signal: PeerSignal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", content = "payload", rename_all = "snake_case")]
pub enum PeerSignal {
    Offer(SdpPayload),
    Answer(SdpPayload),
    IceCandidate(IceCandidatePayload),
    CameraState(CameraStatePayload),
    MicrophoneState(CameraStatePayload),
    ScreenState(CameraStatePayload),
    HandState(HandStatePayload),
    Reaction(ReactionPayload),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SdpPayload {
    pub sdp: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct IceCandidatePayload {
    pub candidate: String,
    pub sdp_mid: Option<String>,
    pub sdp_m_line_index: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CameraStatePayload {
    pub enabled: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HandStatePayload {
    pub raised: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReactionPayload {
    pub emoji: String,
}

#[derive(Debug, Serialize)]
pub struct ServerEnvelope {
    pub version: u8,
    pub event_id: Uuid,
    pub sender: Uuid,
    pub recipient: Uuid,
    pub signal: PeerSignal,
}

#[derive(Debug, PartialEq, Eq)]
pub enum SignalError {
    TooLarge,
    InvalidMessage,
    UnsupportedVersion,
    InvalidRecipient,
    InvalidPayload,
}

/// No incluye membresía ni estado de reunión: esas comprobaciones deben
/// repetirse contra la base de datos inmediatamente antes de retransmitir.
pub fn parse_client_signal(input: &[u8], own_id: Uuid) -> Result<ClientEnvelope, SignalError> {
    if input.len() > MAX_MESSAGE_BYTES {
        return Err(SignalError::TooLarge);
    }
    let envelope: ClientEnvelope =
        serde_json::from_slice(input).map_err(|_| SignalError::InvalidMessage)?;
    if envelope.version != PROTOCOL_VERSION {
        return Err(SignalError::UnsupportedVersion);
    }
    if envelope.event_id.is_nil() || envelope.recipient.is_nil() || envelope.recipient == own_id {
        return Err(SignalError::InvalidRecipient);
    }
    let valid = match &envelope.signal {
        PeerSignal::Offer(sdp) | PeerSignal::Answer(sdp) => {
            !sdp.sdp.trim().is_empty() && sdp.sdp.len() <= MAX_SDP_BYTES
        }
        PeerSignal::IceCandidate(ice) => {
            !ice.candidate.trim().is_empty()
                && ice.candidate.len() <= MAX_ICE_BYTES
                && ice.sdp_mid.as_ref().is_none_or(|mid| mid.len() <= 256)
        }
        PeerSignal::CameraState(_)
        | PeerSignal::MicrophoneState(_)
        | PeerSignal::ScreenState(_)
        | PeerSignal::HandState(_) => true,
        PeerSignal::Reaction(reaction) => matches!(
            reaction.emoji.as_str(),
            "👏" | "👍" | "❤️" | "🎉" | "😀" | "😮"
        ),
    };
    if !valid {
        return Err(SignalError::InvalidPayload);
    }
    Ok(envelope)
}

impl ClientEnvelope {
    /// Sellar el emisor con la identidad validada; nunca usar un campo del JSON.
    pub fn into_server(self, authenticated_sender: Uuid) -> ServerEnvelope {
        ServerEnvelope {
            version: PROTOCOL_VERSION,
            event_id: self.event_id,
            sender: authenticated_sender,
            recipient: self.recipient,
            signal: self.signal,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};

    #[test]
    fn participation_states_require_booleans_and_authenticated_sender() {
        let sender = Uuid::new_v4();
        for (kind, field) in [
            ("microphone_state", "enabled"),
            ("screen_state", "enabled"),
            ("hand_state", "raised"),
        ] {
            for enabled in [false, true] {
                let mut value = message(Uuid::new_v4());
                value["signal"] = json!({"type":kind,"payload":{field:enabled}});
                let server = parse(value.clone(), sender).unwrap().into_server(sender);
                assert_eq!(server.sender, sender);
                value["signal"]["payload"][field] = json!("false");
                assert_eq!(
                    parse(value.clone(), sender).unwrap_err(),
                    SignalError::InvalidMessage
                );
                value["signal"]["payload"] = json!({field:enabled,"sender":Uuid::new_v4()});
                assert_eq!(
                    parse(value, sender).unwrap_err(),
                    SignalError::InvalidMessage
                );
            }
        }
    }

    #[test]
    fn reactions_are_allowlisted_bounded_and_identity_sealed() {
        let sender = Uuid::new_v4();
        for emoji in ["👏", "👍", "❤️", "🎉", "😀", "😮"] {
            let mut value = message(Uuid::new_v4());
            value["signal"] = json!({"type":"reaction","payload":{"emoji":emoji}});
            let server = parse(value, sender).unwrap().into_server(sender);
            assert_eq!(server.sender, sender);
            assert!(matches!(server.signal, PeerSignal::Reaction(_)));
        }
        for invalid in ["", "<script>", "unbounded", "😈"] {
            let mut value = message(Uuid::new_v4());
            value["signal"] = json!({"type":"reaction","payload":{"emoji":invalid}});
            assert_eq!(
                parse(value, sender).unwrap_err(),
                SignalError::InvalidPayload
            );
        }
        let mut value = message(Uuid::new_v4());
        value["signal"] = json!({"type":"reaction","payload":{"emoji":"👏", "duration":999999}});
        assert_eq!(
            parse(value, sender).unwrap_err(),
            SignalError::InvalidMessage
        );
    }

    fn message(recipient: Uuid) -> Value {
        json!({
            "version": 1,
            "event_id": Uuid::new_v4(),
            "recipient": recipient,
            "signal": {"type": "offer", "payload": {"sdp": "v=0\r\n"}},
        })
    }

    fn parse(value: Value, sender: Uuid) -> Result<ClientEnvelope, SignalError> {
        parse_client_signal(value.to_string().as_bytes(), sender)
    }

    #[test]
    fn stamps_authenticated_identity_and_accepts_valid_offer() {
        let sender = Uuid::new_v4();
        let recipient = Uuid::new_v4();
        let value = message(recipient);
        let server = parse(value, sender).unwrap().into_server(sender);
        assert_eq!(server.sender, sender);
        assert_eq!(server.recipient, recipient);
        assert_eq!(server.version, PROTOCOL_VERSION);
    }

    #[test]
    fn rejects_client_supplied_sender() {
        let sender = Uuid::new_v4();
        let mut value = message(Uuid::new_v4());
        value["sender"] = json!(sender);
        assert_eq!(
            parse(value, sender).unwrap_err(),
            SignalError::InvalidMessage
        );
    }

    #[test]
    fn rejects_self_or_missing_recipient() {
        let sender = Uuid::new_v4();
        let mut value = message(sender);
        assert_eq!(
            parse(value.clone(), sender).unwrap_err(),
            SignalError::InvalidRecipient
        );
        value["recipient"] = json!(Uuid::nil());
        assert_eq!(
            parse(value, sender).unwrap_err(),
            SignalError::InvalidRecipient
        );
    }

    #[test]
    fn rejects_unsupported_version_and_event_types() {
        let sender = Uuid::new_v4();
        let mut value = message(Uuid::new_v4());
        value["version"] = json!(2);
        assert_eq!(
            parse(value.clone(), sender).unwrap_err(),
            SignalError::UnsupportedVersion
        );
        value["version"] = json!(1);
        value["signal"]["type"] = json!("kick_participant");
        assert_eq!(
            parse(value, sender).unwrap_err(),
            SignalError::InvalidMessage
        );
    }

    #[test]
    fn rejects_empty_or_oversized_sdp_and_message() {
        let sender = Uuid::new_v4();
        let mut value = message(Uuid::new_v4());
        value["signal"]["payload"]["sdp"] = json!("  ");
        assert_eq!(
            parse(value.clone(), sender).unwrap_err(),
            SignalError::InvalidPayload
        );
        value["signal"]["payload"]["sdp"] = json!("x".repeat(MAX_SDP_BYTES + 1));
        assert_eq!(
            parse(value, sender).unwrap_err(),
            SignalError::InvalidPayload
        );
        assert_eq!(
            parse_client_signal(&vec![b'x'; MAX_MESSAGE_BYTES + 1], sender).unwrap_err(),
            SignalError::TooLarge
        );
    }

    #[test]
    fn accepts_bounded_ice_and_rejects_invalid_candidate() {
        let sender = Uuid::new_v4();
        let mut value = message(Uuid::new_v4());
        value["signal"] = json!({
            "type": "ice_candidate",
            "payload": {"candidate": "candidate:1", "sdp_mid": "0", "sdp_m_line_index": 0}
        });
        assert!(parse(value.clone(), sender).is_ok());
        value["signal"]["payload"]["candidate"] = json!(" ");
        assert_eq!(
            parse(value, sender).unwrap_err(),
            SignalError::InvalidPayload
        );
    }

    #[test]
    fn camera_state_requires_a_boolean_and_rejects_extra_fields() {
        let sender = Uuid::new_v4();
        let mut value = message(Uuid::new_v4());
        value["signal"] = json!({"type": "camera_state", "payload": {"enabled": false}});
        let relayed = parse(value.clone(), sender).unwrap().into_server(sender);
        assert!(matches!(
            relayed.signal,
            PeerSignal::CameraState(CameraStatePayload { enabled: false })
        ));

        value["signal"]["payload"]["enabled"] = json!("false");
        assert_eq!(
            parse(value.clone(), sender).unwrap_err(),
            SignalError::InvalidMessage
        );
        value["signal"]["payload"] = json!({"enabled": false, "sender": "forged"});
        assert_eq!(
            parse(value, sender).unwrap_err(),
            SignalError::InvalidMessage
        );
    }
}
