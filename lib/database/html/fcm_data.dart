import 'package:bluebubbles/services/backend/settings/shared_preferences_service.dart';

class FCMData {
  int? id;
  String? projectID;
  String? storageBucket;
  String? apiKey;
  String? firebaseURL;
  String? clientID;
  String? applicationID;

  FCMData({
    this.id,
    this.projectID,
    this.storageBucket,
    this.apiKey,
    this.firebaseURL,
    this.clientID,
    this.applicationID,
  });

  factory FCMData.fromMap(Map<String, dynamic> json) {
    Map<String, dynamic> projectInfo = json["project_info"];
    Map<String, dynamic> client = json["client"][0];
    String clientID = client["oauth_client"][0]["client_id"];
    return FCMData(
      projectID: projectInfo["project_id"],
      storageBucket: projectInfo["storage_bucket"],
      apiKey: client["api_key"][0]["current_key"],
      firebaseURL: projectInfo["firebase_url"],
      clientID: clientID.contains("-") ? clientID.substring(0, clientID.indexOf("-")) : clientID,
      applicationID: client["client_info"]["mobilesdk_app_id"],
    );
  }

  FCMData save() {
    if (isNull) return this;
    Future.delayed(Duration.zero, () async {
      await PrefsSvc.i.setString('projectID', projectID!);
      await PrefsSvc.i.setString('storageBucket', storageBucket!);
      await PrefsSvc.i.setString('apiKey', apiKey!);
      if (firebaseURL != null) await PrefsSvc.i.setString('firebaseURL', firebaseURL!);
      await PrefsSvc.i.setString('clientID', clientID!);
      await PrefsSvc.i.setString('applicationID', applicationID!);
    });
    return this;
  }

  static void deleteFcmData() async {
    await PrefsSvc.i.remove('projectID');
    await PrefsSvc.i.remove('storageBucket');
    await PrefsSvc.i.remove('apiKey');
    await PrefsSvc.i.remove('firebaseURL');
    await PrefsSvc.i.remove('clientID');
    await PrefsSvc.i.remove('applicationID');
  }

  static FCMData getFCM() {
    return FCMData(
      projectID: PrefsSvc.i.getString('projectID'),
      storageBucket: PrefsSvc.i.getString('storageBucket'),
      apiKey: PrefsSvc.i.getString('apiKey'),
      firebaseURL: PrefsSvc.i.getString('firebaseURL'),
      clientID: PrefsSvc.i.getString('clientID'),
      applicationID: PrefsSvc.i.getString('applicationID'),
    );
  }

  Map<String, dynamic> toMap() => {
        "project_id": projectID,
        "storage_bucket": storageBucket,
        "api_key": apiKey,
        "firebase_url": firebaseURL,
        "client_id": clientID,
        "application_id": applicationID,
      };

  bool get isNull =>
      projectID == null || storageBucket == null || apiKey == null || clientID == null || applicationID == null;
}
