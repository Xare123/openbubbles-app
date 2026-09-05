import 'dart:async';

enum ChatRecipientValidationStatus { pending, supported, unsupported, failed }

enum ChatRecipientValidationFailureKind {
  registrationRepairRequired,
  unavailable,
}

final class ChatRecipientValidationFailure {
  const ChatRecipientValidationFailure(this.kind);

  factory ChatRecipientValidationFailure.fromError(Object error) {
    final description = error.toString().toLowerCase();
    final isTerminalRegistrationFailure =
        description.contains('6005') &&
        (description.contains('registration') ||
            description.contains('authentication'));
    return ChatRecipientValidationFailure(
      isTerminalRegistrationFailure
          ? ChatRecipientValidationFailureKind.registrationRepairRequired
          : ChatRecipientValidationFailureKind.unavailable,
    );
  }

  final ChatRecipientValidationFailureKind kind;

  String get title => switch (kind) {
    ChatRecipientValidationFailureKind.registrationRepairRequired =>
      'iMessage registration needs attention',
    ChatRecipientValidationFailureKind.unavailable =>
      'Could not validate recipient',
  };

  String get message => switch (kind) {
    ChatRecipientValidationFailureKind.registrationRepairRequired =>
      'Open Settings > Profile and choose Repair registration, then try this recipient again. Your saved chats are preserved.',
    ChatRecipientValidationFailureKind.unavailable =>
      'Check your connection, then choose Retry validation.',
  };
}

final class ChatRecipientValidationState {
  const ChatRecipientValidationState._(this.status, [this.failure]);

  const ChatRecipientValidationState.pending()
    : this._(ChatRecipientValidationStatus.pending);

  const ChatRecipientValidationState.supported()
    : this._(ChatRecipientValidationStatus.supported);

  const ChatRecipientValidationState.unsupported()
    : this._(ChatRecipientValidationStatus.unsupported);

  const ChatRecipientValidationState.failed(
    ChatRecipientValidationFailure failure,
  ) : this._(ChatRecipientValidationStatus.failed, failure);

  factory ChatRecipientValidationState.fromKnownEligibility(bool? supported) =>
      supported == null
      ? const ChatRecipientValidationState.pending()
      : supported
      ? const ChatRecipientValidationState.supported()
      : const ChatRecipientValidationState.unsupported();

  final ChatRecipientValidationStatus status;
  final ChatRecipientValidationFailure? failure;

  bool get blocksSend =>
      status == ChatRecipientValidationStatus.pending ||
      status == ChatRecipientValidationStatus.failed;

  bool? get isIMessage => switch (status) {
    ChatRecipientValidationStatus.supported => true,
    ChatRecipientValidationStatus.unsupported => false,
    ChatRecipientValidationStatus.pending ||
    ChatRecipientValidationStatus.failed => null,
  };
}

final class ChatRecipientValidationTicket {
  const ChatRecipientValidationTicket._(this.address, this.generation);

  final String address;
  final int generation;
}

final class ChatRecipientValidationGate {
  ChatRecipientValidationGate({required this.address, bool? knownEligibility})
    : _state = ChatRecipientValidationState.fromKnownEligibility(
        knownEligibility,
      );

  final String address;
  int _generation = 0;
  ChatRecipientValidationState _state;

  ChatRecipientValidationState get state => _state;

  ChatRecipientValidationTicket begin() {
    _generation++;
    _state = const ChatRecipientValidationState.pending();
    return ChatRecipientValidationTicket._(address, _generation);
  }

  bool accept(
    ChatRecipientValidationTicket ticket,
    ChatRecipientValidationState state,
  ) {
    if (ticket.address != address || ticket.generation != _generation) {
      return false;
    }
    _state = state;
    return true;
  }

  void invalidate() {
    _generation++;
  }
}

void completeChatCreationGate(Completer<void>? gate) {
  if (gate != null && !gate.isCompleted) gate.complete();
}
