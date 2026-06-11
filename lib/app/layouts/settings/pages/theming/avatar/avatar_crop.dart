import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:crop_your_image/crop_your_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:image/image.dart' as img;
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:universal_io/io.dart';

class AvatarCrop extends StatefulWidget {
  final int? index;
  final Chat? chat;
  final VoidCallback? cropped;
  const AvatarCrop({super.key, this.index, this.chat, this.cropped});

  @override
  State<AvatarCrop> createState() => _AvatarCropState();
}

class _AvatarCropState extends State<AvatarCrop> with ThemeHelpers {
  final _cropController = CropController();
  Uint8List? _imageData;
  bool _isLoading = true;

  void onCropped(CropResult croppedResult) async {
    Uint8List croppedData;
    switch (croppedResult) {
      case CropSuccess(:final croppedImage):
        croppedData = croppedImage;
        break;
      case CropFailure(:final cause, :final stackTrace):
        Navigator.of(context, rootNavigator: true).pop();
        showSnackbar("Error", "Failed to crop image");
        Logger.debug("Failed to crop image");
        Logger.error(cause);
        Logger.error(stackTrace);
        return;
    }
    final decoded = img.decodeImage(croppedData);
    if (decoded != null) {
      final image = img.copyResize(decoded, width: 570, height: 570);
      croppedData = Uint8List.fromList(img.encodePng(image));
    }

    if (widget.index == null && widget.chat == null) {
      File file = File(p.join(FilesystemSvc.avatarsPath, "you", "avatar-${croppedData.length}.jpg"));
      if (!(await file.exists())) {
        await file.create(recursive: true);
      }
      if (SettingsSvc.settings.userAvatarPath.value != null) {
        await File(SettingsSvc.settings.userAvatarPath.value!).delete();
      }
      await file.writeAsBytes(croppedData);
      SettingsSvc.settings.userAvatarPath.value = file.path;
      await SettingsSvc.settings.saveOneAsync("userAvatarPath");
      Navigator.of(context, rootNavigator: true).pop();
      Navigator.of(context).pop();
      showSnackbar("Notice", "User avatar saved successfully");
    } else if (widget.chat != null) {
      File file = File(p.join(FilesystemSvc.avatarsPath, FilesystemService.sanitizeGuid(widget.chat!.guid),
          "avatar-${croppedData.length}.jpg"));
      if (!(await file.exists())) {
        await file.create(recursive: true);
      }
      if (widget.chat!.customAvatarPath != null) {
        await File(widget.chat!.customAvatarPath!).delete();
      }
      await file.writeAsBytes(croppedData);
      widget.chat!.customAvatarPath = file.path;
      await widget.chat!.saveAsync(updateCustomAvatarPath: true);
      ChatsSvc.getChatState(widget.chat!.guid)?.updateCustomAvatarPathInternal(file.path);
      Navigator.of(context, rootNavigator: true).pop();
      Navigator.of(context).pop(widget.chat!.customAvatarPath);
      showSnackbar("Notice", "Custom chat avatar saved successfully");
    } else {
      File file = File(p.join(FilesystemSvc.avatarsPath, FilesystemService.sanitizeGuid(widget.chat!.guid),
          "avatar-${croppedData.length}.jpg"));
      if (!(await file.exists())) {
        await file.create(recursive: true);
      }
      if (widget.chat!.customAvatarPath != null) {
        await File(widget.chat!.customAvatarPath!).delete();
      }
      await file.writeAsBytes(croppedData);
      widget.chat!.customAvatarPath = file.path;
      await widget.chat!.saveAsync(updateCustomAvatarPath: true);
      Navigator.of(context, rootNavigator: true).pop();
      Navigator.of(context).pop(widget.chat!.customAvatarPath);
      showSnackbar("Notice", "Custom chat avatar saved successfully");
    }
    if (widget.cropped != null) {
      widget.cropped!();
    }
  }

  @override
  Widget build(BuildContext context) {
    return BBScaffold(
      appBar: PreferredSize(
        preferredSize: Size(NavigationSvc.width(context), kIsDesktop ? 80 : 50),
        child: AppBar(
          systemOverlayStyle: context.theme.colorScheme.brightness == Brightness.dark
              ? SystemUiOverlayStyle.light
              : SystemUiOverlayStyle.dark,
          toolbarHeight: kIsDesktop ? 80 : 50,
          elevation: 0,
          scrolledUnderElevation: 3,
          surfaceTintColor: context.theme.colorScheme.primary,
          leading: buildBackButton(context),
          backgroundColor: headerColor,
          centerTitle: iOS,
          title: Text(
            "Select & Crop Avatar",
            style: context.theme.textTheme.titleLarge,
          ),
          actions: [
            AbsorbPointer(
              absorbing: _imageData == null || _isLoading,
              child: TextButton(
                  child: Text("SAVE",
                      style: context.theme.textTheme.bodyLarge!.apply(
                          color: _imageData == null || _isLoading
                              ? context.theme.colorScheme.outline
                              : context.theme.colorScheme.primary)),
                  onPressed: () {
                    showSavingAvatarDialog();
                    _cropController.crop();
                  }),
            ),
          ],
        ),
      ),
      body: SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: Center(
          child: Column(
            children: [
              if (_imageData != null)
                SizedBox(
                  height: context.height / 2,
                  child: Crop(
                    controller: _cropController,
                    image: _imageData!,
                    onCropped: onCropped,
                    onStatusChanged: (status) {
                      if (status == CropStatus.ready || status == CropStatus.cropping) {
                        setState(() {
                          _isLoading = false;
                        });
                      } else {
                        setState(() {
                          _isLoading = true;
                        });
                      }
                    },
                    withCircleUi: true,
                  ),
                ),
              if (_imageData == null)
                SizedBox(
                  height: context.height / 2,
                  child: Center(
                    child:
                        Text("Pick an image to crop it for a custom avatar", style: context.theme.textTheme.bodyLarge),
                  ),
                ),
              const SizedBox(height: 16),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: context.theme.colorScheme.onPrimaryContainer)),
                  backgroundColor: context.theme.colorScheme.primaryContainer,
                ),
                onPressed: () async {
                  final res = await FilePicker.platform
                      .pickFiles(withData: true, type: FileType.custom, allowedExtensions: ['png', 'jpg', 'jpeg']);
                  if (res == null || res.files.isEmpty || res.files.first.bytes == null) return;

                  if (res.files.first.name.endsWith("gif")) {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text("Saving avatar...", style: context.theme.textTheme.titleLarge),
                        content: SizedBox(
                          height: 70,
                          child: Center(
                            child: buildProgressIndicator(context),
                          ),
                        ),
                        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
                      ),
                      barrierDismissible: false,
                    );
                    onCropped(CropSuccess(res.files.first.bytes!));
                  } else {
                    _imageData = res.files.first.bytes!;
                    setState(() {});
                  }
                },
                child: Text(_imageData != null ? "Pick New Image" : "Pick Image",
                    style: context.theme.textTheme.bodyLarge!
                        .copyWith(color: context.theme.colorScheme.onPrimaryContainer)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showSavingAvatarDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Saving avatar...", style: context.theme.textTheme.titleLarge),
        content: SizedBox(
          height: 70,
          child: Center(
            child: buildProgressIndicator(context),
          ),
        ),
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
      ),
      barrierDismissible: false,
    );
  }
}
