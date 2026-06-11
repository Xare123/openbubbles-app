import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/wrappers/bb_scaffold.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:crop_your_image/crop_your_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:path/path.dart' as p;
import 'package:universal_io/io.dart';

class BackgroundCrop extends StatefulWidget {
  final Chat chat;

  const BackgroundCrop({super.key, required this.chat});

  @override
  State<BackgroundCrop> createState() => _BackgroundCropState();
}

class _BackgroundCropState extends State<BackgroundCrop> with ThemeHelpers {
  final _cropController = CropController();
  Uint8List? _imageData;
  bool _isLoading = true;
  bool _isLocked = true;

  Chat get chat => widget.chat;

  void onCropped(CropResult croppedResult) async {
    Uint8List croppedData;
    switch (croppedResult) {
      case CropSuccess(:final croppedImage):
        croppedData = croppedImage;
        break;
      case CropFailure(:final cause, :final stackTrace):
        Navigator.of(context, rootNavigator: true).pop();
        showSnackbar("Error", "Failed to crop image");
        Logger.error(cause);
        Logger.error(stackTrace);
        return;
    }

    final String sanitizedGuid = FilesystemService.sanitizeGuid(chat.guid);
    final File file =
        File(p.join(FilesystemSvc.customBackgroundsPath, sanitizedGuid, "background-${croppedData.length}.png"));

    if (!(await file.exists())) {
      await file.create(recursive: true);
    }

    // Delete the old background file if one exists
    if (chat.customBackgroundPath != null) {
      final File oldFile = File(chat.customBackgroundPath!);
      if (await oldFile.exists()) {
        await oldFile.delete();
      }
    }

    await file.writeAsBytes(croppedData);
    await ChatsSvc.setChatCustomBackgroundPath(chat, file.path);

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();
    Navigator.of(context).pop(file.path);
    showSnackbar("Notice", "Custom background saved successfully");
  }

  @override
  Widget build(BuildContext context) {
    final double screenAspectRatio = NavigationSvc.width(context) / context.height;

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
            "Set Custom Background",
            style: context.theme.textTheme.titleLarge,
          ),
          actions: [
            if (_imageData != null)
              IconButton(
                tooltip: _isLocked ? "Switch to free-form crop" : "Lock to screen ratio",
                icon: Icon(
                  _isLocked
                      ? (iOS ? CupertinoIcons.lock : Icons.lock_outline)
                      : (iOS ? CupertinoIcons.lock_open : Icons.lock_open_outlined),
                ),
                onPressed: () {
                  setState(() {
                    _isLocked = !_isLocked;
                  });
                  _cropController.aspectRatio = _isLocked ? screenAspectRatio : null;
                },
              ),
            AbsorbPointer(
              absorbing: _imageData == null || _isLoading,
              child: TextButton(
                child: Text(
                  "SAVE",
                  style: context.theme.textTheme.bodyLarge!.apply(
                    color: _imageData == null || _isLoading
                        ? context.theme.colorScheme.outline
                        : context.theme.colorScheme.primary,
                  ),
                ),
                onPressed: () {
                  _showSavingDialog();
                  _cropController.crop();
                },
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _imageData != null
                ? Crop(
                    controller: _cropController,
                    image: _imageData!,
                    onCropped: onCropped,
                    onStatusChanged: (status) {
                      setState(() {
                        _isLoading = status != CropStatus.ready && status != CropStatus.cropping;
                      });
                    },
                    withCircleUi: false,
                    aspectRatio: _isLocked ? screenAspectRatio : null,
                  )
                : Center(
                    child: Text(
                      "Pick an image to use as the chat background",
                      style: context.theme.textTheme.bodyLarge,
                      textAlign: TextAlign.center,
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
                side: BorderSide(color: context.theme.colorScheme.onPrimaryContainer),
              ),
              backgroundColor: context.theme.colorScheme.primaryContainer,
            ),
            onPressed: () async {
              final res = await FilePicker.platform.pickFiles(
                withData: true,
                type: FileType.custom,
                allowedExtensions: ['png', 'jpg', 'jpeg'],
              );
              if (res == null || res.files.isEmpty || res.files.first.bytes == null) return;

              setState(() {
                _imageData = res.files.first.bytes!;
                _isLoading = true;
              });
            },
            child: Text(
              _imageData != null ? "Pick New Image" : "Pick Image",
              style: context.theme.textTheme.bodyLarge!.copyWith(color: context.theme.colorScheme.onPrimaryContainer),
            ),
          ),
          SizedBox(height: MediaQuery.of(context).padding.bottom + 16),
        ],
      ),
    );
  }

  void _showSavingDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Saving background...", style: context.theme.textTheme.titleLarge),
        content: SizedBox(
          height: 70,
          child: Center(child: buildProgressIndicator(context)),
        ),
        backgroundColor: context.theme.colorScheme.surfaceContainerHighest,
      ),
      barrierDismissible: false,
    );
  }
}
