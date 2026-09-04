import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:faker/faker.dart';
import 'package:tuple/tuple.dart';

class MessagePart {
  MessagePart({
    this.subject,
    this.text,
    this.attachments = const [],
    this.annotations = const [],
    this.isUnsent = false,
    this.edits = const [],
    required this.part,
  }) {
    if (attachments.isEmpty) attachments = [];
    if (annotations.isEmpty) annotations = [];
    if (edits.isEmpty) edits = [];
  }

  String? subject;
  late final String fakeSubject = faker.lorem.words(subject?.split(" ").length ?? 0).join(" ");
  String? get displaySubject {
    if (subject == null) return null;
    if (ss.settings.redactedMode.value && ss.settings.hideMessageContent.value) {
      return fakeSubject;
    }
    return subject;
  }
  String? text;
  late final String fakeText = faker.lorem.words(text?.split(" ").length ?? 0).join(" ");
  String? get displayText {
    if (text == null) return null;
    if (ss.settings.redactedMode.value && ss.settings.hideMessageContent.value) {
      return fakeText;
    }
    return text;
  }
  List<Attachment> attachments;
  List<Annotation> annotations;
  bool isUnsent;
  List<MessagePart> edits;
  int part;

  bool get isEdited => edits.isNotEmpty;
  String? get url => text?.replaceAll("\n", " ").split(" ").firstWhereOrNull((String e) => e.hasUrl);
  String get fullText => sanitizeString([subject, text].where((e) => !isNullOrEmpty(e)).join("\n"));
}

class Annotation {
  Annotation({
    this.mentionedAddress,
    this.textEffect,
    this.bold,
    this.italic,
    this.strikethrough,
    this.underline,
    this.range = const [],
    List<Tuple3<String, List<int>, List?>>? renderExtras,
  }) : renderExtras = renderExtras ?? [];

  Map<String, dynamic> toMap() {
    // Only include non-null values
    final Map<String, dynamic> map = {};
    if (mentionedAddress != null) map["mentionedAddress"] = mentionedAddress;
    if (textEffect != null) map["textEffect"] = textEffect;
    if (bold ?? false) map["bold"] = bold;
    if (italic ?? false) map["italic"] = italic;
    if (strikethrough ?? false) map["strikethrough"] = strikethrough;
    if (underline ?? false) map["underline"] = underline;
    map["range"] = range;
    return map;
  }

  factory Annotation.fromMap(Map<String, dynamic> json) => Annotation(
    mentionedAddress: json["mentionedAddress"],
    textEffect: json["textEffect"],
    bold: json["bold"],
    italic: json["italic"],
    strikethrough: json["strikethrough"],
    underline: json["underline"],
    range: [json["range"][0], json["range"][1]],
  );

  int? textEffect;
  bool? bold;
  bool? italic;
  bool? strikethrough;
  bool? underline;

  List<Tuple3<String, List<int>, List?>> renderExtras = [];

  String? mentionedAddress;
  List<int> range;

  bool eqUnranged(Annotation other) {
    return (other.textEffect ?? false) == (textEffect ?? false) &&
      (other.bold ?? false) == (bold ?? false) &&
      (other.italic ?? false) == (italic ?? false) &&
      (other.strikethrough ?? false) == (strikethrough ?? false) &&
      (other.underline ?? false) == (underline ?? false) && 
      (other.mentionedAddress ?? false) == (mentionedAddress ?? false);
  }

  void applyTo(Annotation other) {
    if (mentionedAddress != null) other.mentionedAddress = mentionedAddress;
    if (bold != null) other.bold = bold;
    if (italic != null) other.italic = italic;
    if (strikethrough != null) other.strikethrough = strikethrough;
    if (underline != null) other.underline = underline;
    if (textEffect != null) {
      other.textEffect = textEffect;
      other.bold = null;
      other.italic = null;
      other.strikethrough = null;
      other.underline = null;
    } else {
      other.textEffect = null;
    }
  }

  Annotation copy() {
    return Annotation(
      bold: bold, 
      textEffect: textEffect, 
      italic: italic, 
      strikethrough: strikethrough, 
      underline: underline, 
      range: [...range], 
      mentionedAddress: mentionedAddress,
      renderExtras: [...renderExtras],
    );
  }
}
