import 'dart:convert';

const extensionTestBundle = 'com.example.synthetic';

String extensionTestJson({String name = 'Synthetic App', String bundleId = extensionTestBundle}) => jsonEncode({
  'version': 1,
  'metadata': {
    'name': name,
    'app_id': 1234,
    'bundle_id': bundleId,
    'balloon': {
      'url': 'app:synthetic',
      'session': '01010101-0101-0101-0101-010101010101',
      'ld_text': 'Synthetic description',
      'is_live': true,
      'icon': [0, 1, 127, 128, 255],
      'layout': {
        'image_subtitle': 'is',
        'image_title': 'it',
        'caption': 'c',
        'secondary_subcaption': 'ss',
        'tertiary_subcaption': 'ts',
        'subcaption': 's',
      },
    },
  },
});
