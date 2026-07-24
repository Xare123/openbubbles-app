import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:bluebubbles/app/components/avatars/contact_avatar_widget.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_location_clipper.dart';
import 'package:bluebubbles/app/layouts/findmy/findmy_pin_clipper.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/content/next_button.dart';
import 'package:bluebubbles/app/wrappers/scrollbar_wrapper.dart';
import 'package:bluebubbles/app/wrappers/theme_switcher.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/app/layouts/settings/widgets/settings_widgets.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/services/rustpush/rustpush_service.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_popup/flutter_map_marker_popup.dart';
import 'package:get/get.dart' hide Response;
import 'package:latlong2/latlong.dart';
import 'package:maps_launcher/maps_launcher.dart';
import 'package:sliding_up_panel2/sliding_up_panel2.dart';
import 'package:tuple/tuple.dart';
import 'package:universal_io/io.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:url_launcher/url_launcher.dart';

enum _FindMySection { devices, items, people }

extension on _FindMySection {
  int get visibleIndex => _FindMySection.values.indexOf(this);

  int get pageIndex => this == _FindMySection.people ? 1 : 0;

  String get label => switch (this) {
        _FindMySection.devices => 'Devices',
        _FindMySection.items => 'Items',
        _FindMySection.people => 'People',
      };

  String get singularLabel => switch (this) {
        _FindMySection.devices => 'Device',
        _FindMySection.items => 'Item',
        _FindMySection.people => 'Person',
      };
}

class _FindMySearchItem {
  const _FindMySearchItem({
    required this.section,
    required this.title,
    required this.subtitle,
    required this.queryText,
    this.device,
    this.friend,
  });

  final _FindMySection section;
  final String title;
  final String subtitle;
  final String queryText;
  final FindMyDevice? device;
  final FindMyFriend? friend;
}

class _FindMySearchDelegate extends SearchDelegate<_FindMySearchItem?> {
  _FindMySearchDelegate({required this.items});

  final List<_FindMySearchItem> items;

  @override
  String get searchFieldLabel => 'Search devices, items, and people';

  @override
  List<Widget>? buildActions(BuildContext context) => [
        if (query.isNotEmpty)
          IconButton(
            onPressed: () => query = '',
            icon: const Icon(Icons.clear),
          ),
      ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
        onPressed: () => close(context, null),
        icon: const Icon(Icons.arrow_back),
      );

  @override
  Widget buildResults(BuildContext context) => _buildList(context);

  @override
  Widget buildSuggestions(BuildContext context) => _buildList(context);

  Widget _buildList(BuildContext context) {
    final normalizedQuery = query.trim().toLowerCase();
    final filtered = normalizedQuery.isEmpty
        ? items
        : items.where((item) => item.queryText.contains(normalizedQuery)).toList(growable: false);

    if (filtered.isEmpty) {
      return const Center(child: Text('No matching devices, items, or people.'));
    }

    return ListView.separated(
      itemCount: filtered.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: Theme.of(context).dividerColor.withOpacity(0.35)),
      itemBuilder: (context, index) {
        final item = filtered[index];
        return ListTile(
          onTap: () => close(context, item),
          leading: Icon(switch (item.section) {
            _FindMySection.devices => ss.settings.skin.value == Skins.iOS ? CupertinoIcons.device_desktop : Icons.devices,
            _FindMySection.items => ss.settings.skin.value == Skins.iOS ? CupertinoIcons.location : Icons.location_on_outlined,
            _FindMySection.people => ss.settings.skin.value == Skins.iOS ? CupertinoIcons.person_2 : Icons.person,
          }),
          title: Text(item.title),
          subtitle: Text('${item.section.label} · ${item.subtitle}'),
          trailing: const Icon(Icons.chevron_right),
        );
      },
    );
  }
}

class FindMyPage extends StatefulWidget {
  FindMyPage({super.key, this.defaultFriend});

  String? defaultFriend;

  @override
  State<StatefulWidget> createState() => _FindMyPageState();
}

class _FindMyPageState extends OptimizedState<FindMyPage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final ScrollController controller1 = ScrollController();
  final ScrollController controller2 = ScrollController();
  late final TabController tabController = TabController(vsync: this, length: 2);
  final PanelController panelController = PanelController();
  final RxInt index = 0.obs;
  final PopupController popupController = PopupController();
  final MapController mapController = MapController();
  final completer = Completer<void>();
  final GlobalKey _devicesSectionKey = GlobalKey();
  final GlobalKey _itemsSectionKey = GlobalKey();
  final Expando<String> _friendMarkerFallbacks = Expando<String>();
  final Expando<String> _deviceMarkerFallbacks = Expando<String>();
  int _nextFriendMarkerFallback = 0;
  int _nextDeviceMarkerFallback = 0;

  StreamSubscription? locationSub;
  List<FindMyDevice> devices = [];
  List<FindMyFriend> friends = [];
  List<FindMyFriend> friendsWithLocation = [];
  List<FindMyFriend> friendsWithoutLocation = [];
  Map<String, Marker> markers = {};
  Position? location;
  bool? fetching = true;
  bool refreshing = false;
  bool? fetching2 = true;
  bool refreshing2 = false;
  bool canRefresh = false;
  bool isInClique = true;

  Map<(double, double), Address> cachedAddresses = {};

  List<api.DartBeacon> cachedBeacons = [];
  DateTime? beaconCacheDate;

  Timer? myTimer;
  bool _refreshInProgress = false;
  bool _appInForeground = true;
  bool _pageIsActive = true;
  final String _diagnosticCaptureId = _newDiagnosticId();
  int _nextDiagnosticOperation = 0;

  bool get _isPageVisible => mounted && _pageIsActive && (ModalRoute.of(context)?.isCurrent ?? true);

  api.FindMyFriendsClientDefaultAnisetteProvider? fmfClient;
  api.FindMyPhoneClientDefaultAnisetteProvider? fmipClient;

  static String _newDiagnosticId() {
    final random = Random.secure();
    final value = List<int>.generate(12, (_) => random.nextInt(256));
    return base64UrlEncode(value).replaceAll('=', '');
  }

  String _nextOperationId() => 'op-${++_nextDiagnosticOperation}-${_newDiagnosticId()}';

  /// Logs only stable diagnostic fields. Do not add user, device, location, or
  /// server-derived values here: this logger is intentionally safe to collect.
  void _logDiagnostic(
    String category,
    String event, {
    String? operationId,
    String? source,
    String? status,
    String? errorType,
    int? durationMs,
    int? resultCount,
  }) {
    final record = <String, Object>{
      'schema': 'openbubbles.findmy.diag.v1',
      'capture_id': _diagnosticCaptureId,
      'category': category,
      'event': event,
      if (operationId != null) 'operation_id': operationId,
      if (source != null) 'source': source,
      if (status != null) 'status': status,
      if (errorType != null) 'error_type': errorType,
      if (durationMs != null) 'duration_ms': durationMs,
      if (resultCount != null) 'result_count': resultCount,
    };
    Logger.info('[FindMyDiag] ${jsonEncode(record)}', tag: 'FindMy');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    _appInForeground = lifecycleState == null || lifecycleState == AppLifecycleState.resumed;
    _logDiagnostic('lifecycle', 'initialized', status: _appInForeground ? 'foreground' : 'background');
    tabController.addListener(_syncSectionWithPage);
    if (widget.defaultFriend != null) {
      index.value = _FindMySection.people.visibleIndex;
      tabController.index = 1;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => getLocations(source: 'initial'));
    _startRefreshTimer();

    socket.socket.on("new-findmy-location", (data) {
      try {
        final friend = FindMyFriend.fromJson(data);
        _logDiagnostic('socket_update', 'received');
        if ((friend.latitude ?? 0) == 0 && (friend.longitude ?? 0) == 0) {
          _logDiagnostic('socket_update', 'ignored', status: 'no_location');
          return;
        }
        final existingFriendIndex = friends.indexWhere((e) => e.handle?.uniqueAddressAndService == friend.handle?.uniqueAddressAndService);
        final existingFriend = existingFriendIndex == -1 ? null : friends[existingFriendIndex];
        if (existingFriend == null || existingFriend.status == null || friend.locatingInProgress || LocationStatus.values.indexOf(existingFriend.status!) <= LocationStatus.values.indexOf(friend.status ?? LocationStatus.legacy)) {
          if (existingFriendIndex == -1) {
            friends.add(friend);
          } else {
            friends[existingFriendIndex] = friend;
          }

          friendsWithLocation = friends.where((item) => (item.latitude ?? 0) != 0 && (item.longitude ?? 0) != 0).toList();
          friendsWithoutLocation = friends.where((item) => (item.latitude ?? 0) == 0 && (item.longitude ?? 0) == 0).toList();

          _rebuildFriendMarkers();
          setState(() {});
          _logDiagnostic('socket_update', 'applied');
        } else {
          _logDiagnostic('socket_update', 'ignored', status: 'stale');
        }
      } catch (error) {
        _logDiagnostic('socket_update', 'error', status: 'parse_failed', errorType: error.runtimeType.toString());
      }
    });
  }

  void _syncSectionWithPage() {
    if (!mounted || tabController.indexIsChanging) return;
    if (tabController.index == _FindMySection.people.pageIndex) {
      index.value = _FindMySection.people.visibleIndex;
    } else if (index.value == _FindMySection.people.visibleIndex) {
      index.value = _FindMySection.devices.visibleIndex;
    }
  }

  void _startRefreshTimer() {
    myTimer?.cancel();
    if (!_appInForeground || !_pageIsActive) return;
    myTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (_appInForeground && _isPageVisible) {
        getLocations(refreshDevices: false, source: 'foreground_timer');
      }
    });
  }

  void _stopRefreshTimer() {
    myTimer?.cancel();
    myTimer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appInForeground = state == AppLifecycleState.resumed;
    _logDiagnostic('lifecycle', 'state_changed', status: _appInForeground ? 'foreground' : 'background');
    if (_appInForeground) {
      _startRefreshTimer();
    } else {
      _stopRefreshTimer();
    }
  }

  @override
  void activate() {
    super.activate();
    _pageIsActive = true;
    _logDiagnostic('lifecycle', 'activated');
    _startRefreshTimer();
  }

  @override
  void deactivate() {
    _pageIsActive = false;
    _logDiagnostic('lifecycle', 'deactivated');
    _stopRefreshTimer();
    super.deactivate();
  }

  Future<void> _refreshManually() async {
    if (!canRefresh || _refreshInProgress || !_appInForeground || !_isPageVisible) {
      _logDiagnostic('refresh', 'skipped', source: 'manual', status: 'unavailable');
      return;
    }
    setState(() {
      canRefresh = false;
      refreshing = true;
      refreshing2 = true;
    });
    await getLocations(source: 'manual');
  }

  /// Fetches the FindMy data from the server.
  /// The toggles for refresh friends & devices are separate due to an inconsistency in the server API.
  /// As of v1.9.7 (server), the refresh devices endpoint doesn't return the devices data,
  /// however, the refresh friends endpoint does. The way this was coded assumes that the server
  /// will return the data for both endpoints. A server update will fix this, but for now,
  /// we will "patch" it by only "refreshing" devices when the user manually refreshes the data.
  Future<void> getLocations({bool refreshFriends = true, bool refreshDevices = true, String source = 'internal'}) async {
    if (!_appInForeground) {
      _logDiagnostic('refresh', 'skipped', source: source, status: 'not_foreground');
      return;
    }
    if (!_isPageVisible) {
      _logDiagnostic('refresh', 'skipped', source: source, status: 'not_visible');
      return;
    }
    if (_refreshInProgress) {
      _logDiagnostic('refresh', 'skipped', source: source, status: 'in_progress');
      return;
    }
    final operationId = _nextOperationId();
    final startedAt = Stopwatch()..start();
    var refreshSucceeded = false;
    _logDiagnostic('refresh', 'started', operationId: operationId, source: source);
    _refreshInProgress = true;
    try {
    if (!(Platform.isLinux && !kIsWeb)) {
      LocationPermission granted = await Geolocator.checkPermission();
      if (granted == LocationPermission.denied) {
        granted = await Geolocator.requestPermission();
      }
      if (granted == LocationPermission.whileInUse || granted == LocationPermission.always) {
        Geolocator.getCurrentPosition(locationSettings: const LocationSettings(timeLimit: Duration(seconds: 30))).then((loc) {
          if (!mounted) return;
          if (ss.settings.lastLocation.value == null) {
            mapController.move(LatLng(loc.latitude, loc.longitude), 10);
          }
          ss.settings.lastLocation.value = "${loc.latitude},${loc.longitude}";
          ss.saveSettings();
          location = loc;
          buildLocationMarker(location!);
          if (!kIsDesktop && locationSub == null) {
            locationSub = Geolocator.getPositionStream().listen((event) {
              ss.settings.lastLocation.value = "${event.latitude},${event.longitude}";
              ss.saveSettings();
              setState(() {
                buildLocationMarker(event);
              });
            }, onError: (Object error, StackTrace stackTrace) {
              _logDiagnostic('api', 'error', operationId: operationId, status: 'position_stream', errorType: error.runtimeType.toString());
            });
          }
          if (!refreshFriends) {
            mapController.move(LatLng(location!.latitude, location!.longitude), 10);
          }
        }, onError: (Object error, StackTrace stackTrace) {
          _logDiagnostic('api', 'error', operationId: operationId, status: 'current_position', errorType: error.runtimeType.toString());
        });
      }
    }

    var isNew = fmfClient == null;
    if (isNew) _logDiagnostic('api', 'started', operationId: operationId, status: 'create_friends_client');
    fmfClient ??= await api.makeFindMyFriends(
      path: pushService.statePath,
      config: pushService.state!.osConfig,
      aps: pushService.state!.conn,
      anisette: pushService.state!.anisette,
      provider: pushService.state!.icloudServices!.tokenProvider,
    );
    if (isNew) _logDiagnostic('api', 'succeeded', operationId: operationId, status: 'create_friends_client');

    try {
      if (refreshFriends && !isNew) {
        _logDiagnostic('api', 'started', operationId: operationId, status: 'refresh_following');
        await api.refreshFollowing(config: pushService.state!.osConfig, client: fmfClient!);
        _logDiagnostic('api', 'succeeded', operationId: operationId, status: 'refresh_following');
      }

      _logDiagnostic('api', 'started', operationId: operationId, status: 'get_following');
      var following = await api.getFollowing(client: fmfClient!);
      _logDiagnostic('api', 'succeeded', operationId: operationId, status: 'get_following', resultCount: following.length);
    
      friends = following
          .map((e) => 
            FindMyFriend(
              latitude: e.lastLocation?.latitude,
              longitude: e.lastLocation?.longitude,
              longAddress: e.lastLocation?.address?.formattedAddressLines?.join("\n"), 
              shortAddress: e.lastLocation?.address != null ? "${e.lastLocation?.address?.locality}, ${e.lastLocation?.address?.stateCode ?? e.lastLocation?.address?.countryCode}" : null,
              title: null, 
              subtitle: null, 
              handle: Handle.findOne(addressAndService: Tuple2(e.invitationAcceptedHandles.first, "iMessage")) ?? Handle(address: e.invitationAcceptedHandles.first), 
              lastUpdated: e.lastLocation?.timestamp != null ? DateTime.fromMillisecondsSinceEpoch(e.lastLocation!.timestamp) : null,
              status: null, 
              locatingInProgress: false,
              id: e.id,
            )
          )
          .toList()
          .cast<FindMyFriend>();

      friendsWithLocation = friends.where((item) => (item.latitude ?? 0) != 0 && (item.longitude ?? 0) != 0).toList();
      friendsWithoutLocation = friends.where((item) => (item.latitude ?? 0) == 0 && (item.longitude ?? 0) == 0).toList();

      if (!mounted) return;
      _rebuildFriendMarkers();
      setState(() {
        fetching2 = false;
        refreshing2 = false;
      });
      if (widget.defaultFriend != null) {
        var friend = friends.firstWhereOrNull((friend) => friend.id == widget.defaultFriend);
        widget.defaultFriend = null;
        if (friend != null) {
          await _selectFriend(friend, refreshLocation: true);
        }
      }
    } catch (e) {
      _logDiagnostic('api', 'error', operationId: operationId, status: 'people_data', errorType: e.runtimeType.toString());
      if (mounted) {
        setState(() {
          fetching2 = null;
          refreshing2 = false;
        });
      }
      return;
    }

    var isNewi = fmipClient == null;
    if (isNewi) _logDiagnostic('api', 'started', operationId: operationId, status: 'create_devices_client');
    fmipClient ??= await api.makeFindMyPhone(
      config: pushService.state!.osConfig,
      path: pushService.statePath,
      aps: pushService.state!.conn,
      anisette: pushService.state!.anisette,
      provider: pushService.state!.icloudServices!.tokenProvider,
    );
    if (isNewi) _logDiagnostic('api', 'succeeded', operationId: operationId, status: 'create_devices_client');


    try {
      if (refreshDevices && !isNewi) {
        _logDiagnostic('api', 'started', operationId: operationId, status: 'refresh_devices');
        await api.refreshDevices(config: pushService.state!.osConfig, client: fmipClient!);
        _logDiagnostic('api', 'succeeded', operationId: operationId, status: 'refresh_devices');
      }

      _logDiagnostic('api', 'started', operationId: operationId, status: 'get_devices');
      var following = await api.getDevices(client: fmipClient!);
      _logDiagnostic('api', 'succeeded', operationId: operationId, status: 'get_devices', resultCount: following.length);
    
      var devices = following
          .map((e) => 
            FindMyDevice(
              deviceModel: e.deviceModel, 
              lowPowerMode: e.lowPowerMode, 
              passcodeLength: e.passcodeLength, 
              itemGroup: null, 
              id: e.id, 
              batteryStatus: e.batteryStatus, 
              audioChannels: [], 
              lostModeCapable: e.lostModeCapable, 
              snd: null, 
              batteryLevel: e.batteryLevel, 
              locationEnabled: e.locationEnabled, 
              isConsideredAccessory: e.isConsideredAccessory ?? false, 
              address: null, 
              location: e.location != null ? Location(
                positionType: e.location!.positionType, 
                verticalAccuracy: e.location!.verticalAccuracy.round(), 
                longitude: e.location!.longitude, 
                floorLevel: e.location!.floorLevel, 
                isInaccurate: e.location!.isInaccurate, 
                isOld: e.location!.isOld, 
                horizontalAccuracy: e.location!.horizontalAccuracy, 
                latitude: e.location!.latitude, 
                timeStamp: e.location!.timestamp, 
                altitude: e.location!.altitude.round(), 
                locationFinished: e.location!.locationFinished
                ) : null, 
              modelDisplayName: e.modelDisplayName, 
              deviceColor: e.deviceColor, 
              activationLocked: e.activationLocked, 
              rm2State: e.rm2State, 
              locFoundEnabled: e.locFoundEnabled, 
              nwd: e.nwd, 
              deviceStatus: e.deviceStatus, 
              remoteWipe: null, 
              fmlyShare: e.fmlyShare, 
              thisDevice: e.thisDevice, 
              lostDevice: null, 
              lostModeEnabled: e.lostModeEnabled, 
              deviceDisplayName: e.deviceDisplayName, 
              safeLocations: null, 
              name: e.name, 
              canWipeAfterLock: e.canWipeAfterLock, 
              isMac: e.isMac, 
              rawDeviceModel: e.rawDeviceModel, 
              baUuid: e.baUuid, 
              trackingInfo: null,
              features: e.features, 
              deviceDiscoveryId: e.deviceDiscoveryId, 
              prsId: null, 
              scd: e.scd, 
              locationCapable: e.locationCapable, 
              remoteLock: null, 
              wipeInProgress: e.wipeInProgress, 
              darkWake: e.darkWake, 
              deviceWithYou: e.deviceWithYou, 
              maxMsgChar: e.maxMsgChar, 
              deviceClass: e.deviceClass, 
              crowdSourcedLocation: null, 
              role: null,
              lostModeMetadata: null
            )
          )
          .toList().cast<FindMyDevice>();
      

      if (beaconCacheDate == null || DateTime.now().difference(beaconCacheDate!).inMinutes > 3) {
        isInClique = await api.isInClique(keychain: pushService.state!.icloudServices!.keychain!);
        try {
          _logDiagnostic('api', 'started', operationId: operationId, status: 'get_beacon_items');
          cachedBeacons = isInClique ? await api.getBeaconItems(items: pushService.state!.icloudServices!.fmfd!) : [];
          _logDiagnostic('api', 'succeeded', operationId: operationId, status: 'get_beacon_items', resultCount: cachedBeacons.length);
        } catch (e) {
          // used for PCS key missing catching after we reset the clique.
          _logDiagnostic('api', 'error', operationId: operationId, status: 'get_beacon_items', errorType: e.runtimeType.toString());
        }
        beaconCacheDate = DateTime.now();
        for (var cached in cachedBeacons) {
          if (cached.lastReport == null) continue;
          try {
            var placemark = await pushService.reverseGeocode(cached.lastReport!.lat, cached.lastReport!.long);
            if (placemark != null) {
              cachedAddresses[(cached.lastReport!.lat, cached.lastReport!.long)] = Address(
                subAdministrativeArea: placemark.subAdministrativeArea,
                label: placemark.thoroughfare ?? placemark.name,
                streetAddress: placemark.thoroughfare,
                country: placemark.country,
                countryCode: placemark.isoCountryCode,
                administrativeArea: placemark.administrativeArea,
                streetName: placemark.thoroughfare,
                formattedAddressLines: [
                  if (placemark.thoroughfare != null)
                  placemark.thoroughfare!,
                  if (placemark.locality != null)
                  placemark.locality!,
                  if (placemark.administrativeArea != null)
                  placemark.administrativeArea!,
                ],
                locality: placemark.locality,
                stateCode: placemark.administrativeArea?.substring(0, 2).toUpperCase(),
                mapItemFullAddress: null,
                fullThroroughfare: null,
                areaOfInterest: [],
              );
            }
          } catch (e) {
            _logDiagnostic('api', 'error', operationId: operationId, status: 'reverse_geocode', errorType: e.runtimeType.toString());
          }
        }
      }
      for (api.DartBeacon e in cachedBeacons) {
        var location = e.lastReport != null ? Location(
            positionType: null, 
            verticalAccuracy: e.lastReport!.confidence, 
            longitude: e.lastReport!.long, 
            floorLevel: null, 
            isInaccurate: null, 
            isOld: null, 
            horizontalAccuracy: e.lastReport!.horizontalAccuracy.toDouble(), 
            latitude: e.lastReport!.lat, 
            timeStamp: api.systemtimeToMillis(time: e.lastReport!.timestamp), 
            altitude: null, 
            locationFinished: true,
            ) : null;
        if (e.productId == -1) {
          var existingDevice = devices.firstWhereOrNull((d) => d.name == e.naming.name && !d.isConsideredAccessory);
          if (existingDevice == null || e.lastReport == null) continue;
          if (existingDevice.location?.timeStamp != null && api.systemtimeToMillis(time: e.lastReport!.timestamp) < existingDevice.location!.timeStamp!) continue; // report is older
          existingDevice.location = location;
          continue; // this is an iDevice
        }
        devices.add(FindMyDevice(
          deviceModel: e.model, 
          lowPowerMode: false, 
          passcodeLength: null, 
          itemGroup: null, 
          id: e.id, 
          batteryStatus: null, 
          audioChannels: [], 
          lostModeCapable: true, 
          snd: null, 
          batteryLevel: e.batteryLevel?.toDouble(), 
          locationEnabled: true, 
          isConsideredAccessory: true, 
          address: e.lastReport == null ? null : cachedAddresses[(e.lastReport!.lat, e.lastReport!.long)], 
          location: location, 
          modelDisplayName: null, 
          deviceColor: null, 
          activationLocked: false, 
          rm2State: null, 
          locFoundEnabled: false, 
          nwd: null, 
          deviceStatus: null, 
          remoteWipe: null, 
          fmlyShare: null, 
          thisDevice: false, 
          lostDevice: null, 
          lostModeEnabled: false, 
          deviceDisplayName: e.naming.name, 
          safeLocations: null, 
          name: e.naming.name, 
          canWipeAfterLock: false, 
          isMac: false, 
          rawDeviceModel: e.model,
          baUuid: null,
          trackingInfo: null,
          features: null,
          deviceDiscoveryId: null,
          prsId: null, 
          scd: null,
          locationCapable: null,
          remoteLock: null, 
          wipeInProgress: null,
          darkWake: null,
          deviceWithYou: false,
          maxMsgChar: null,
          deviceClass: null,
          crowdSourcedLocation: null, 
          role: {
            "emoji": e.naming.emoji,
            "sharingId": e.shared?.shareId,
            "sharingActive": e.shared?.acceptanceState,
            "sharingName": e.shared?.ownerHandle != null ? RustPushBBUtils.rustHandleToBB(e.shared!.ownerHandle).displayName : null,
          },
          lostModeMetadata: null
        ));
      }

      this.devices = devices;

      if (!mounted) return;
      _rebuildDeviceMarkers();
      setState(() {
        fetching = false;
        refreshing = false;
      });
      refreshSucceeded = true;
    } catch (e) {
      _logDiagnostic('api', 'error', operationId: operationId, status: 'device_data', errorType: e.runtimeType.toString());
      if (mounted) {
        setState(() {
          fetching = null;
          refreshing = false;
        });
      }
      return;
    }
    } catch (e) {
      _logDiagnostic('refresh', 'error', operationId: operationId, source: source, status: 'unexpected', errorType: e.runtimeType.toString());
      if (mounted) {
        setState(() {
          fetching = null;
          fetching2 = null;
        });
      }
    } finally {
      startedAt.stop();
      _refreshInProgress = false;
      if (mounted) {
        setState(() {
          refreshing = false;
          refreshing2 = false;
          canRefresh = true;
        });
      }
      _logDiagnostic(
        'refresh',
        refreshSucceeded ? 'succeeded' : 'failed',
        operationId: operationId,
        source: source,
        durationMs: startedAt.elapsedMilliseconds,
        resultCount: friends.length + devices.length,
      );
    }
  }

  String _friendMarkerKey(FindMyFriend friend) {
    final identifier = friend.handle?.uniqueAddressAndService ?? friend.id;
    if (identifier != null && identifier.isNotEmpty) return 'friend-$identifier';
    return 'friend-${_friendMarkerFallbacks[friend] ??= 'fallback-${_nextFriendMarkerFallback++}'}';
  }

  String _deviceMarkerKey(FindMyDevice device) {
    final identifier = device.id ?? device.deviceDiscoveryId ?? device.prsId ?? device.baUuid;
    if (identifier != null && identifier.isNotEmpty) return 'device-$identifier';
    return 'device-${_deviceMarkerFallbacks[device] ??= 'fallback-${_nextDeviceMarkerFallback++}'}';
  }

  _FindMySection _sectionForDevice(FindMyDevice device) =>
      device.isConsideredAccessory ? _FindMySection.items : _FindMySection.devices;

  List<_FindMySearchItem> _buildSearchItems() {
    if (ss.settings.redactedMode.value) return const [];
    return [
        for (final device in devices)
          _FindMySearchItem(
            section: _sectionForDevice(device),
            title: device.name ?? device.modelDisplayName ?? 'Unknown ${_sectionForDevice(device).singularLabel}',
            subtitle: device.address?.label ?? device.address?.mapItemFullAddress ?? 'No location found',
            queryText: [
              device.name,
              device.modelDisplayName,
              device.deviceModel,
              device.address?.label,
              device.address?.mapItemFullAddress,
              device.address?.locality,
            ].whereType<String>().join(' ').toLowerCase(),
            device: device,
          ),
        for (final friend in friends)
          _FindMySearchItem(
            section: _FindMySection.people,
            title: friend.handle?.displayName ?? friend.title ?? 'Unknown Person',
            subtitle: friend.shortAddress ?? friend.longAddress ?? 'No location found',
            queryText: [
              friend.handle?.displayName,
              friend.handle?.address,
              friend.title,
              friend.subtitle,
              friend.shortAddress,
              friend.longAddress,
            ].whereType<String>().join(' ').toLowerCase(),
            friend: friend,
          ),
      ];
  }

  Future<void> _openSearch(BuildContext context) async {
    if (ss.settings.redactedMode.value) return;
    final result = await showSearch<_FindMySearchItem?>(
      context: context,
      delegate: _FindMySearchDelegate(items: _buildSearchItems()),
    );
    if (!mounted || result == null) return;
    _logDiagnostic('map', 'search_result_selected');
    if (result?.device != null) {
      await _selectDevice(result!.device!);
    } else if (result?.friend != null) {
      await _selectFriend(result!.friend!);
    }
  }

  Future<void> _showSection(_FindMySection section, {bool togglePanel = false}) async {
    if (!mounted) return;
    final wasSelected = index.value == section.visibleIndex;
    if (!wasSelected) _logDiagnostic('map', 'section_changed');
    index.value = section.visibleIndex;
    if (tabController.index != section.pageIndex) {
      tabController.animateTo(section.pageIndex);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (!mounted) return;
    }
    if (context.isPhone) {
      if (togglePanel && wasSelected && panelController.isPanelOpen) {
        await panelController.close();
      } else if (!panelController.isPanelOpen) {
        await panelController.open();
      }
    }
    if (!mounted) return;
    await _scrollToSection(section);
  }

  Future<void> _scrollToSection(_FindMySection section) async {
    if (section == _FindMySection.people) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final anchorContext =
        (section == _FindMySection.items ? _itemsSectionKey : _devicesSectionKey).currentContext;
    if (anchorContext == null) return;
    await Scrollable.ensureVisible(
      anchorContext,
      alignment: 0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  Future<void> _focusMarker(String markerKey, double? latitude, double? longitude) async {
    if (latitude == null || longitude == null) return;
    try {
      await completer.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      _logDiagnostic('map', 'error', status: 'map_not_ready', errorType: 'TimeoutException');
      return;
    }
    if (!mounted) return;
    if (context.isPhone && panelController.isPanelOpen) {
      await panelController.close();
    }
    if (!mounted) return;
    final marker = markers[markerKey];
    if (marker != null) {
      popupController.showPopupsOnlyFor([marker]);
    }
    mapController.move(LatLng(latitude, longitude), 10);
    _logDiagnostic('map', 'focused');
  }

  Future<void> _selectDevice(FindMyDevice device) async {
    try {
      await _showSection(_sectionForDevice(device));
      if (!mounted) return;
      await _focusMarker(_deviceMarkerKey(device), device.location?.latitude, device.location?.longitude);
    } catch (error) {
      _logDiagnostic('map', 'error', status: 'device_selection', errorType: error.runtimeType.toString());
    }
  }

  Future<void> _selectFriend(FindMyFriend friend, {bool refreshLocation = false}) async {
    try {
      await _showSection(_FindMySection.people);
      if (!mounted) return;
      final hasLocation = (friend.latitude ?? 0) != 0 && (friend.longitude ?? 0) != 0;
      if ((refreshLocation || !hasLocation) && fmfClient != null && friend.id != null) {
        await api.selectFriend(config: pushService.state!.osConfig, client: fmfClient!, friend: friend.id);
        if (!mounted) return;
      }
      await _focusMarker(_friendMarkerKey(friend), friend.latitude, friend.longitude);
    } catch (error) {
      _logDiagnostic('map', 'error', status: 'friend_selection', errorType: error.runtimeType.toString());
    }
  }

  void _rebuildFriendMarkers() {
    markers.removeWhere((key, _) => key.startsWith('friend-'));
    for (final friend in friendsWithLocation) {
      buildFriendMarker(friend);
    }
    _logDiagnostic('map', 'markers_rebuilt', resultCount: friendsWithLocation.length);
  }

  void _rebuildDeviceMarkers() {
    markers.removeWhere((key, _) => key.startsWith('device-'));
    for (final device in devices.where((device) => device.location?.latitude != null && device.location?.longitude != null)) {
      markers[_deviceMarkerKey(device)] = Marker(
        key: ValueKey(_deviceMarkerKey(device)),
        point: LatLng(device.location!.latitude!, device.location!.longitude!),
        width: 30,
        height: 35,
        child: ClipShadowPath(
          clipper: const FindMyPinClipper(),
          shadow: const BoxShadow(
            color: Colors.black,
            blurRadius: 2,
          ),
          child: Container(
            color: Colors.white,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 5.0),
                child: device.role?['emoji'] != null
                    ? Text(device.role!['emoji'], style: context.theme.textTheme.bodyLarge!.copyWith(fontFamily: 'Apple Color Emoji'))
                    : Icon(
                        (device.isMac ?? false)
                            ? CupertinoIcons.desktopcomputer
                            : device.isConsideredAccessory
                                ? CupertinoIcons.headphones
                                : CupertinoIcons.device_phone_portrait,
                        color: Colors.black,
                        size: 20,
                      ),
              ),
            ),
          ),
        ),
        alignment: Alignment.topCenter,
      );
    }
    _logDiagnostic('map', 'markers_rebuilt', resultCount: markers.length);
  }

  void buildFriendMarker(FindMyFriend friend) {
    markers[_friendMarkerKey(friend)] = Marker(
      key: ValueKey(_friendMarkerKey(friend)),
      point: LatLng(friend.latitude!, friend.longitude!),
      width: 35,
      height: 35,
      child: Container(
        decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(3),
            child:
            ContactAvatarWidget(editable: false, handle: friend.handle ?? Handle(address: friend.title ?? "Unknown")),
          ),
        ),
      ),
      alignment: Alignment.topCenter,
    );
  }

  void buildLocationMarker(Position pos) {
    markers['current'] = Marker(
      key: const ValueKey('current'),
      point: LatLng(pos.latitude, pos.longitude),
      width: 25,
      height: 55,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (pos.heading.isFinite)
            Transform.rotate(
              angle: pos.heading,
              child: ClipPath(
                clipper: const FindMyLocationClipper(),
                child: Container(
                  width: 25,
                  height: 55,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: AlignmentDirectional.center,
                      end: Alignment.topCenter,
                      colors: [context.theme.colorScheme.primary, context.theme.colorScheme.primary.withAlpha(50)],
                    ),
                  ),
                ),
              ),
            ),
          Container(
            width: 25,
            height: 25,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
            ),
            padding: const EdgeInsets.all(5),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: context.theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
      alignment: Alignment.topCenter,
    );
  }

  Future<void> deleteShared(FindMyDevice item) async {
    await api.deleteBeaconShare(items: pushService.state!.icloudServices!.fmfd!, share: item.role!['sharingId']!);
    setState(() {
      devices.remove(item);
      _rebuildDeviceMarkers();
    });
    beaconCacheDate = null;
  }

  Future<void> addShared(FindMyDevice item) async {
    await api.acceptBeaconShare(items: pushService.state!.icloudServices!.fmfd!, share: item.role!['sharingId']!);
    setState(() {
      devices.remove(item); // it'll go away anyways because it has no location
      _rebuildDeviceMarkers();
    });
    beaconCacheDate = null;
    getLocations(source: 'item_share_changed');
  }

  @override
  void dispose() {
    _logDiagnostic('lifecycle', 'disposed');
    locationSub?.cancel();
    mapController.dispose();
    popupController.dispose();
    tabController.removeListener(_syncSectionWithPage);
    tabController.dispose();
    _stopRefreshTimer();
    WidgetsBinding.instance.removeObserver(this);
    // TODO
    socket.socket.off("new-findmy-location");
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final devicesWithLocation = devices
        .where(
            (item) => item.location?.latitude != null && !item.isConsideredAccessory)
        .toList();
    final itemsWithLocation = devices
        .where(
            (item) => (item.location?.latitude != null || item.role?["sharingActive"] == 0) && item.isConsideredAccessory)
        .toList();
    final withoutLocation =
        devices.where((item) => item.location?.latitude == null && item.role?["sharingActive"] != 0).toList();
    final devicesBodySlivers = [
      SliverList(
        delegate: SliverChildListDelegate([
          SizedBox(key: _devicesSectionKey, height: 0),
          if (fetching == null || fetching == true || (fetching == false && devices.isEmpty))
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 100),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        fetching == null
                            ? "Something went wrong!"
                            : fetching == false
                                ? "You have no devices."
                                : "Getting FindMy data...",
                        style: context.theme.textTheme.labelLarge,
                      ),
                    ),
                    if (fetching == true) buildProgressIndicator(context, size: 15),
                  ],
                ),
              ),
            ),
          if (devicesWithLocation.isNotEmpty)
            SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "Devices"),
          if (devicesWithLocation.isNotEmpty)
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Material(
                  color: Colors.transparent,
                  child: ListView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    findChildIndexCallback: (key) => findChildIndexByKey(devicesWithLocation, key, _deviceMarkerKey),
                    itemBuilder: (context, i) {
                      final item = devicesWithLocation[i];
                      return ListTile(
                        key: ValueKey(_deviceMarkerKey(item)),
                        mouseCursor: MouseCursor.defer,
                        title: Text(ss.settings.redactedMode.value ? "Device" : (item.name ?? "Unknown Device")),
                        onTap: item.location?.latitude != null && item.location?.longitude != null
                            ? () => _selectDevice(item)
                            : null,
                        trailing: item.location?.latitude != null && item.location?.longitude != null ? ButtonTheme(
                          minWidth: 1,
                          child: TextButton(
                            style: TextButton.styleFrom(
                              shape: const CircleBorder(),
                              backgroundColor: context.theme.colorScheme.primaryContainer,
                            ),
                            onPressed: () async {
                              await MapsLauncher.launchCoordinates(item.location!.latitude!, item.location!.longitude!);
                            },
                            child: const Icon(
                                Icons.directions,
                                size: 20
                            ),
                          ),
                        ) : null,
                        onLongPress: () async {
                          const encoder = JsonEncoder.withIndent("     ");
                          final str = encoder.convert(item.toJson());
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(
                                "Raw FindMy Data",
                                style: context.theme.textTheme.titleLarge,
                              ),
                              backgroundColor: context.theme.colorScheme.properSurface,
                              content: SizedBox(
                                width: ns.width(context) * 3 / 5,
                                height: context.height * 1 / 4,
                                child: Container(
                                  padding: const EdgeInsets.all(10.0),
                                  decoration: BoxDecoration(
                                      color: context.theme.colorScheme.background,
                                      borderRadius: const BorderRadius.all(Radius.circular(10))),
                                  child: SingleChildScrollView(
                                    child: SelectableText(
                                      str,
                                      style: context.theme.textTheme.bodyLarge,
                                    ),
                                  ),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  child: Text("Close",
                                      style: context.theme.textTheme.bodyLarge!
                                          .copyWith(color: context.theme.colorScheme.primary)),
                                  onPressed: () => Navigator.of(context).pop(),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                    itemCount: devicesWithLocation.length,
                  ),
                ),
              ],
            ),
          SizedBox(key: _itemsSectionKey, height: 0),
          if (itemsWithLocation.isNotEmpty || !isInClique)
            SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "Items"),
          if (!isInClique)
          Obx(() => SettingsSection(
            backgroundColor: tileColor,
            children: [
              SettingsTile(
                title: "Show Airtags",
                onTap: () async {
                  if (pushService.state?.icloudServices?.keychain == null) {
                    showSnackbar("Relog required!", "Relog required to use Backup! Relog in Settings -> Reconfigure");
                    return;
                  }
                  if (!await pushService.joinClique()) return;
                  beaconCacheDate = null;
                  getLocations(source: 'clique_joined');
                },
                trailing: const NextButton(),
              ),
            ]
        )),
          if (itemsWithLocation.isNotEmpty)
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Material(
                  color: Colors.transparent,
                  child: ListView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    findChildIndexCallback: (key) => findChildIndexByKey(itemsWithLocation, key, _deviceMarkerKey),
                    itemBuilder: (context, i) {
                      final item = itemsWithLocation[i];
                      var tile = ListTile(
                        key: ValueKey(_deviceMarkerKey(item)),
                        title: Text(ss.settings.redactedMode.value ? "Item" : (item.name ?? "Unknown Item")),
                        subtitle: item.role?["sharingActive"] == 0 ? Column(
                          children: [
                            Text("${item.role?["sharingName"]} wants to share this item with you."),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: context.theme.colorScheme.outline.withAlpha(64),
                                    padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 13),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    elevation: 0.0,
                                    minimumSize: Size.zero,
                                  ),
                                  onPressed: () async {
                                    pushService.wrapPromise(deleteShared(item), "Removing...");
                                  },
                                  child: Text("Don't Add", style: context.theme.textTheme.titleMedium),
                                ),
                                const SizedBox(width: 10),
                                ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: context.theme.colorScheme.primary,
                                    padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 13),
                                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    elevation: 0.0,
                                    minimumSize: Size.zero,
                                  ),
                                  onPressed: () async {
                                    pushService.wrapPromise(addShared(item), "Adding...");
                                  },
                                  child: Text("Add", style: context.theme.textTheme.titleMedium?.apply(color: context.theme.colorScheme.onPrimary)),
                                ),
                              ],
                            )
                          ],
                        )
                          : Text(ss.settings.redactedMode.value ? "Location" : (item.address?.label ?? item.address?.mapItemFullAddress ?? "No location found")),
                        trailing: item.location?.latitude != null && item.location?.longitude != null ? ButtonTheme(
                          minWidth: 1,
                          child: TextButton(
                            style: TextButton.styleFrom(
                              shape: const CircleBorder(),
                              backgroundColor: context.theme.colorScheme.primaryContainer,
                            ),
                            onPressed: () async {
                              await MapsLauncher.launchCoordinates(item.location!.latitude!, item.location!.longitude!);
                            },
                            child: const Icon(
                                Icons.directions,
                                size: 20
                            ),
                          ),
                        ) : null,
                        onTap: item.location?.latitude != null && item.location?.longitude != null
                            ? () => _selectDevice(item)
                            : null,
                        onLongPress: () async {
                          const encoder = JsonEncoder.withIndent("     ");
                          final str = encoder.convert(item.toJson());
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(
                                "Raw FindMy Data",
                                style: context.theme.textTheme.titleLarge,
                              ),
                              backgroundColor: context.theme.colorScheme.properSurface,
                              content: SizedBox(
                                width: ns.width(context) * 3 / 5,
                                height: context.height * 1 / 4,
                                child: Container(
                                  padding: const EdgeInsets.all(10.0),
                                  decoration: BoxDecoration(
                                      color: context.theme.colorScheme.background,
                                      borderRadius: const BorderRadius.all(Radius.circular(10))),
                                  child: SingleChildScrollView(
                                    child: SelectableText(
                                      str,
                                      style: context.theme.textTheme.bodyLarge,
                                    ),
                                  ),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  child: Text("Close",
                                      style: context.theme.textTheme.bodyLarge!
                                          .copyWith(color: context.theme.colorScheme.primary)),
                                  onPressed: () => Navigator.of(context).pop(),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                      if (item.role?['sharingId'] != null) {
                        return wrapDelete(tile, (context) => deleteShared(item));
                      }
                      return tile;
                    },
                    itemCount: itemsWithLocation.length,
                  ),
                ),
              ],
            ),
          if (withoutLocation.isNotEmpty)
            SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "Unknown Location"),
          if (withoutLocation.isNotEmpty)
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Material(
                  color: Colors.transparent,
                  child: ExpansionTile(
                      shape: const RoundedRectangleBorder(side: BorderSide(color: Colors.transparent)),
                      title: const Text("Devices without locations"),
                      children: withoutLocation
                          .map((item) {
                            var tile = ListTile(
                                title: Text(ss.settings.redactedMode.value ? "Device" : (item.name ?? "Unknown Device")),
                                subtitle: Text(ss.settings.redactedMode.value ? "Location" : (item.address?.label ?? item.address?.mapItemFullAddress ?? "No location found")),
                                onTap: null,
                                onLongPress: () async {
                                  const encoder = JsonEncoder.withIndent("     ");
                                  final str = encoder.convert(item.toJson());
                                  showDialog(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text(
                                        "Raw FindMy Data",
                                        style: context.theme.textTheme.titleLarge,
                                      ),
                                      backgroundColor: context.theme.colorScheme.properSurface,
                                      content: SizedBox(
                                        width: ns.width(context) * 3 / 5,
                                        height: context.height * 1 / 4,
                                        child: Container(
                                          padding: const EdgeInsets.all(10.0),
                                          decoration: BoxDecoration(
                                              color: context.theme.colorScheme.background,
                                              borderRadius: const BorderRadius.all(Radius.circular(10))),
                                          child: SingleChildScrollView(
                                            child: SelectableText(
                                              str,
                                              style: context.theme.textTheme.bodyLarge,
                                            ),
                                          ),
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          child: Text("Close",
                                              style: context.theme.textTheme.bodyLarge!
                                                  .copyWith(color: context.theme.colorScheme.primary)),
                                          onPressed: () => Navigator.of(context).pop(),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              );
                              if (item.role?['sharingId'] != null) {
                                return wrapDelete(tile, (context) => deleteShared(item));
                              }
                              return tile;
                            })
                          .toList()),
                ),
              ],
            ),
        ]),
      ),
    ];

    final friendsBodySlivers = [
      SliverList(
        delegate: SliverChildListDelegate([
          if (fetching2 == null || fetching2 == true || (fetching2 == false && friends.isEmpty))
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 100),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(
                        fetching2 == null
                            ? "Something went wrong!"
                            : fetching2 == false
                                ? "You have no people."
                                : "Getting FindMy data...",
                        style: context.theme.textTheme.labelLarge,
                      ),
                    ),
                    if (fetching2 == true) buildProgressIndicator(context, size: 15),
                  ],
                ),
              ),
            ),
          if (friendsWithLocation.isNotEmpty)
            SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "People"),
          if (friendsWithLocation.isNotEmpty)
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Material(
                  color: Colors.transparent,
                  child: ListView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    findChildIndexCallback: (key) => findChildIndexByKey(friendsWithLocation, key, _friendMarkerKey),
                    itemBuilder: (context, i) {
                      final item = friendsWithLocation[i];
                      return ListTile(
                        key: ValueKey(_friendMarkerKey(item)),
                        leading: ContactAvatarWidget(handle: item.handle),
                        title: Text(item.handle?.displayName ?? item.title ?? "Unknown Person"),
                        subtitle: Text(ss.settings.redactedMode.value ? "Location" : ("${item.shortAddress ?? "No location found"}${item.lastUpdated == null || item.status == LocationStatus.live ? "" : "\nLast updated ${buildDate(item.lastUpdated)}"}")),
                        trailing: item.latitude != null && item.longitude != null ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (item.status == LocationStatus.live)
                              const Icon(CupertinoIcons.largecircle_fill_circle),
                            if (item.locatingInProgress)
                              buildProgressIndicator(context),
                            ButtonTheme(
                              minWidth: 1,
                              child: TextButton(
                                style: TextButton.styleFrom(
                                  shape: const CircleBorder(),
                                  backgroundColor: context.theme.colorScheme.primaryContainer,
                                ),
                                onPressed: () async {
                                  await MapsLauncher.launchCoordinates(item.latitude!, item.longitude!);
                                },
                                child: const Icon(
                                    Icons.directions,
                                    size: 20
                                ),
                              ),
                            ),
                          ],
                        ) : null,
                        onTap: () => _selectFriend(item),
                        onLongPress: () async {
                          const encoder = JsonEncoder.withIndent("     ");
                          final str = encoder.convert(item.toJson());
                          showDialog(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text(
                                "Raw FindMy Data",
                                style: context.theme.textTheme.titleLarge,
                              ),
                              backgroundColor: context.theme.colorScheme.properSurface,
                              content: SizedBox(
                                width: ns.width(context) * 3 / 5,
                                height: context.height / 2,
                                child: Container(
                                  padding: const EdgeInsets.all(10.0),
                                  decoration: BoxDecoration(
                                      color: context.theme.colorScheme.background,
                                      borderRadius: const BorderRadius.all(Radius.circular(10))),
                                  child: SingleChildScrollView(
                                    child: SelectableText(
                                      str,
                                      style: context.theme.textTheme.bodyLarge,
                                    ),
                                  ),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  child: Text("Close",
                                      style: context.theme.textTheme.bodyLarge!
                                          .copyWith(color: context.theme.colorScheme.primary)),
                                  onPressed: () => Navigator.of(context).pop(),
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                    itemCount: friendsWithLocation.length,
                  ),
                ),
              ],
            ),
          if (friendsWithoutLocation.isNotEmpty)
            SettingsHeader(iosSubtitle: iosSubtitle, materialSubtitle: materialSubtitle, text: "Unknown Location"),
          if (friendsWithoutLocation.isNotEmpty)
            SettingsSection(
              backgroundColor: tileColor,
              children: [
                Material(
                  color: Colors.transparent,
                  child: ExpansionTile(
                      shape: const RoundedRectangleBorder(side: BorderSide(color: Colors.transparent)),
                      title: const Text("People without locations"),
                      children: friendsWithoutLocation
                          .map((item) => ListTile(
                                mouseCursor: MouseCursor.defer,
                                leading: ContactAvatarWidget(handle: item.handle),
                                title: Text(item.handle?.displayName ?? item.title ?? "Unknown Person"),
                                subtitle: Text(ss.settings.redactedMode.value ? "Location" : (item.longAddress ?? "No location found")),
                                onTap: () => _selectFriend(item),
                                onLongPress: () async {
                                  const encoder = JsonEncoder.withIndent("     ");
                                  final str = encoder.convert(item.toJson());
                                  showDialog(
                                    context: context,
                                    builder: (context) => AlertDialog(
                                      title: Text(
                                        "Raw FindMy Data",
                                        style: context.theme.textTheme.titleLarge,
                                      ),
                                      backgroundColor: context.theme.colorScheme.properSurface,
                                      content: SizedBox(
                                        width: ns.width(context) * 3 / 5,
                                        height: context.height * 1 / 4,
                                        child: Container(
                                          padding: const EdgeInsets.all(10.0),
                                          decoration: BoxDecoration(
                                              color: context.theme.colorScheme.background,
                                              borderRadius: const BorderRadius.all(Radius.circular(10))),
                                          child: SingleChildScrollView(
                                            child: SelectableText(
                                              str,
                                              style: context.theme.textTheme.bodyLarge,
                                            ),
                                          ),
                                        ),
                                      ),
                                      actions: [
                                        TextButton(
                                          child: Text("Close",
                                              style: context.theme.textTheme.bodyLarge!
                                                  .copyWith(color: context.theme.colorScheme.primary)),
                                          onPressed: () => Navigator.of(context).pop(),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ))
                          .toList()),
                ),
              ],
            ),
        ]),
      ),
    ];

    return AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle(
          systemNavigationBarColor: ss.settings.immersiveMode.value
              ? Colors.transparent
              : context.theme.colorScheme.background, // navigation bar color
          systemNavigationBarIconBrightness: context.theme.colorScheme.brightness.opposite,
          statusBarColor: Colors.transparent, // status bar color
          statusBarIconBrightness: Brightness.dark,
        ),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            if (context.isPhone) {
              return buildNormal(context, devicesBodySlivers, friendsBodySlivers);
            }
            return buildTabletLayout(context, devicesBodySlivers, friendsBodySlivers);
          },
        ));
  }

  Widget buildTabletLayout(BuildContext context, List<SliverList> devicesBodySlivers, List<SliverList> friendsBodySlivers) {
    return Obx(
      () => Scaffold(
        backgroundColor: context.theme.colorScheme.background.themeOpacity(context),
        body: Stack(
          children: [
            Row(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(minWidth: 300, maxWidth: max(300, min(500, ns.width(context) / 3))),
                  child: Container(
                    width: 500,
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      buildMap(),
                      if (!samsung)
                        Positioned(
                          top: 10 + (kIsDesktop ? appWindow.titleBarHeight : MediaQuery.of(context).padding.top),
                          right: (canRefresh || refreshing || refreshing2) ? 76 : 20,
                          child: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Theme.of(context).colorScheme.properSurface.withOpacity(0.9),
                            ),
                            child: IconButton(
                              icon: const Icon(Icons.search),
                              onPressed: ss.settings.redactedMode.value ? null : () => _openSearch(context),
                            ),
                          ),
                        ),
                      if (!samsung && (canRefresh || refreshing || refreshing2))
                        Positioned(
                          top: 10 + (kIsDesktop ? appWindow.titleBarHeight : MediaQuery.of(context).padding.top),
                          right: 20,
                          child: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Theme.of(context).colorScheme.properSurface.withOpacity(0.9),
                            ),
                            child: Container(
                              width: 48,
                              child: refreshing || refreshing2
                                  ? buildProgressIndicator(context)
                                  : IconButton(
                                      iconSize: 22,
                                      icon: Icon(iOS ? CupertinoIcons.arrow_counterclockwise : Icons.refresh,
                                          color: context.theme.colorScheme.onBackground, size: 22),
                                      onPressed: _refreshManually,
                                    ),
                            ),
                          ),
                        ),
                      if (kIsDesktop)
                        SizedBox(
                          height: appWindow.titleBarHeight,
                          child: AbsorbPointer(
                            child: Row(children: [
                              Expanded(child: Container()),
                              ClipRect(
                                child: BackdropFilter(
                                  filter: ImageFilter.blur(sigmaY: 2, sigmaX: 2),
                                  child: Container(
                                      height: appWindow.titleBarHeight,
                                      width: appWindow.titleBarButtonSize.width * 3,
                                      color: context.theme.colorScheme.properSurface.withOpacity(0.5)),
                                ),
                              ),
                            ]),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            ConstrainedBox(
              constraints: BoxConstraints(minWidth: 300, maxWidth: max(300, min(500, ns.width(context) / 3))),
              child: Column(
                children: [
                  if (!samsung)
                    Container(
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            margin: const EdgeInsets.symmetric(horizontal: 8),
                            child: buildBackButton(context),
                          ),
                          Expanded(child: Text("Find My", style: context.theme.textTheme.titleLarge)),
                        ],
                      ),
                    ),
                  if (!samsung) buildDesktopTabBar(),
                  Expanded(
                    child: Container(
                      width: 500,
                      child: TabBarView(
                        controller: tabController,
                        children: [
                          ScrollbarWrapper(
                            controller: controller1,
                            child: CustomScrollView(
                              controller: controller1,
                              slivers: [
                                if (samsung) buildSamsungAppBar(context, "FindMy Devices"),
                                if (ss.settings.skin.value != Skins.Samsung) ...devicesBodySlivers,
                                if (ss.settings.skin.value == Skins.Samsung)
                                  SliverToBoxAdapter(
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                          minHeight: context.height -
                                              50 -
                                              context.mediaQueryPadding.top -
                                              context.mediaQueryViewPadding.top),
                                      child: CustomScrollView(
                                        physics: const NeverScrollableScrollPhysics(),
                                        shrinkWrap: true,
                                        slivers: devicesBodySlivers,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          ScrollbarWrapper(
                            controller: controller2,
                            child: CustomScrollView(
                              controller: controller2,
                              slivers: [
                                if (samsung) buildSamsungAppBar(context, "FindMy People"),
                                if (!samsung) ...friendsBodySlivers,
                                if (samsung)
                                  SliverToBoxAdapter(
                                    child: ConstrainedBox(
                                      constraints: BoxConstraints(
                                          minHeight: context.height -
                                              50 -
                                              context.mediaQueryPadding.top -
                                              context.mediaQueryViewPadding.top),
                                      child: CustomScrollView(
                                        physics: const NeverScrollableScrollPhysics(),
                                        shrinkWrap: true,
                                        slivers: friendsBodySlivers,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (samsung) buildDesktopTabBar()
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildDesktopTabBar() {
    return Obx(() => Row(
          children: [
            _buildSectionTab(_FindMySection.devices, iOS ? CupertinoIcons.device_desktop : Icons.devices),
            _buildSectionTab(_FindMySection.items, iOS ? CupertinoIcons.location : Icons.location_on_outlined),
            _buildSectionTab(_FindMySection.people, iOS ? CupertinoIcons.person_2 : Icons.person),
          ],
        ));
  }

  Widget _buildSectionTab(_FindMySection section, IconData icon) {
    final selected = index.value == section.visibleIndex;
    return Expanded(
      child: InkWell(
        onTap: () => _showSection(section),
        child: Container(
          padding: const EdgeInsets.only(top: 8, bottom: 6),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? context.theme.colorScheme.primary : context.theme.dividerColor.withOpacity(0.2),
                width: selected ? 2 : 1,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: selected ? context.theme.colorScheme.primary : null),
              Text(section.label, style: context.theme.textTheme.labelSmall?.copyWith(color: selected ? context.theme.colorScheme.primary : null)),
            ],
          ),
        ),
      ),
    );
  }

  Widget wrapDelete(Widget child, Function(BuildContext) onPressed) {
    return Slidable(
      endActionPane: ActionPane(
        motion: const StretchMotion(),
        extentRatio: 0.30,
        children: [
          SlidableAction(
            label: 'Remove',
            backgroundColor: Colors.red,
            icon: ss.settings.skin.value == Skins.iOS ? CupertinoIcons.trash : Icons.delete_outlined,
            onPressed: (_) async {
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (BuildContext context) {
                  return AlertDialog(
                    backgroundColor: context.theme.colorScheme.properSurface,
                    title: Text(
                      "Deleting...",
                      style: context.theme.textTheme.titleLarge,
                    ),
                    content: Container(
                      height: 70,
                      child: Center(child: buildProgressIndicator(context)),
                    ),
                  );
                }
              );
              await onPressed(context);
              Get.back();
            },
          ),
        ],
      ),
      child: child,
    );
  }

  Widget buildNormal(BuildContext context, List<SliverList> devicesBodySlivers, List<SliverList> friendsBodySlivers) {
    return Obx(
      () => Scaffold(
        backgroundColor: material ? tileColor : headerColor,
        body: Stack(
          children: [
            SlidingUpPanel(
              controller: panelController,
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(25.0),
                topRight: Radius.circular(25.0),
              ),
              minHeight: 50,
              maxHeight: MediaQuery.of(context).size.height * 0.75,
              disableDraggableOnScrolling: true,
              backdropEnabled: true,
              parallaxEnabled: true,
              header: ForceDraggableWidget(
                child: SizedBox(
                  width: MediaQuery.of(context).size.width,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 10.0, bottom: 40),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Container(
                        width: 50,
                        height: 5,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.outline,
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              panelBuilder: () => TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                controller: tabController,
                children: <Widget>[
                  NotificationListener<ScrollEndNotification>(
                    onNotification: (_) {
                      if (ss.settings.skin.value != Skins.Samsung || kIsWeb || kIsDesktop) return false;
                      final scrollDistance = context.height / 3 - 57;

                      if (controller1.offset > 0 && controller1.offset < scrollDistance) {
                        final double snapOffset = controller1.offset / scrollDistance > 0.5 ? scrollDistance : 0;

                        Future.microtask(() => controller1.animateTo(snapOffset,
                            duration: const Duration(milliseconds: 200), curve: Curves.linear));
                      }
                      return false;
                    },
                    child: ScrollbarWrapper(
                      controller: controller1,
                      child: Obx(
                        () => CustomScrollView(
                          controller: controller1,
                          physics: (kIsDesktop || kIsWeb)
                              ? const NeverScrollableScrollPhysics()
                              : ThemeSwitcher.getScrollPhysics(),
                          slivers: <Widget>[
                            if (samsung) buildSamsungAppBar(context, "FindMy Devices"),
                            if (ss.settings.skin.value != Skins.Samsung) ...devicesBodySlivers,
                            if (ss.settings.skin.value == Skins.Samsung)
                              SliverToBoxAdapter(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                      minHeight: context.height -
                                          50 -
                                          context.mediaQueryPadding.top -
                                          context.mediaQueryViewPadding.top),
                                  child: CustomScrollView(
                                    physics: const NeverScrollableScrollPhysics(),
                                    shrinkWrap: true,
                                    slivers: devicesBodySlivers,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  NotificationListener<ScrollEndNotification>(
                    onNotification: (_) {
                      if (ss.settings.skin.value != Skins.Samsung || kIsWeb || kIsDesktop) return false;
                      final scrollDistance = context.height / 3 - 57;

                      if (controller2.offset > 0 && controller2.offset < scrollDistance) {
                        final double snapOffset = controller2.offset / scrollDistance > 0.5 ? scrollDistance : 0;

                        Future.microtask(() => controller2.animateTo(snapOffset,
                            duration: const Duration(milliseconds: 200), curve: Curves.linear));
                      }
                      return false;
                    },
                    child: ScrollbarWrapper(
                      controller: controller2,
                      child: Obx(
                        () => CustomScrollView(
                          controller: controller2,
                          physics: (kIsDesktop || kIsWeb)
                              ? const NeverScrollableScrollPhysics()
                              : ThemeSwitcher.getScrollPhysics(),
                          slivers: <Widget>[
                            if (samsung) buildSamsungAppBar(context, "FindMy People"),
                            if (ss.settings.skin.value != Skins.Samsung) ...friendsBodySlivers,
                            if (ss.settings.skin.value == Skins.Samsung)
                              SliverToBoxAdapter(
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                      minHeight: context.height -
                                          50 -
                                          context.mediaQueryPadding.top -
                                          context.mediaQueryViewPadding.top),
                                  child: CustomScrollView(
                                    physics: const NeverScrollableScrollPhysics(),
                                    shrinkWrap: true,
                                    slivers: friendsBodySlivers,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              body: buildMap(),
            ),
            if (!samsung)
              Positioned(
                  top: 10 + (kIsDesktop ? appWindow.titleBarHeight : MediaQuery.of(context).padding.top),
                  left: 20,
                  child: Container(
                    width: 48,
                    height: 48,
                    child: buildBackButton(context, padding: const EdgeInsets.only(right: 2)),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).colorScheme.properSurface.withOpacity(0.9),
                    ),
                  )),
            if (!samsung)
              Positioned(
                top: 10 + (kIsDesktop ? appWindow.titleBarHeight : MediaQuery.of(context).padding.top),
                right: (canRefresh || refreshing || refreshing2) ? 76 : 20,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.properSurface.withOpacity(0.9),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: ss.settings.redactedMode.value ? null : () => _openSearch(context),
                  ),
                ),
              ),
            if (!samsung && (canRefresh || refreshing || refreshing2))
              Positioned(
                top: 10 + (kIsDesktop ? appWindow.titleBarHeight : MediaQuery.of(context).padding.top),
                right: 20,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).colorScheme.properSurface.withOpacity(0.9),
                  ),
                  child: Container(
                    width: 48,
                    child: refreshing || refreshing2
                        ? buildProgressIndicator(context)
                        : IconButton(
                            iconSize: 22,
                            icon: Icon(iOS ? CupertinoIcons.arrow_counterclockwise : Icons.refresh,
                                color: context.theme.colorScheme.onBackground, size: 22),
                            onPressed: _refreshManually,
                          ),
                  ),
                ),
              ),
            if (kIsDesktop)
              SizedBox(
                height: appWindow.titleBarHeight,
                child: AbsorbPointer(
                  child: Row(children: [
                    Expanded(child: Container()),
                    ClipRect(
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaY: 2, sigmaX: 2),
                        child: Container(
                            height: appWindow.titleBarHeight,
                            width: appWindow.titleBarButtonSize.width * 3,
                            color: context.theme.colorScheme.properSurface.withOpacity(0.5)),
                      ),
                    ),
                  ]),
                ),
              ),
          ],
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: index.value,
          backgroundColor: headerColor,
          destinations: [
            NavigationDestination(
              icon: Icon(iOS ? CupertinoIcons.device_desktop : Icons.devices),
              label: "DEVICES",
            ),
            NavigationDestination(
              icon: Icon(iOS ? CupertinoIcons.location : Icons.location_on_outlined),
              label: "ITEMS",
            ),
            NavigationDestination(
              icon: Icon(iOS ? CupertinoIcons.person_2 : Icons.person),
              label: "PEOPLE",
            ),
          ],
          onDestinationSelected: (page) => _showSection(_FindMySection.values[page], togglePanel: true),
        ),
      ),
    );
  }

  Widget buildSamsungAppBar(BuildContext context, String title) {
    final actions = [
      Container(
        width: 48,
        height: 48,
        margin: const EdgeInsets.only(right: 8),
        child: IconButton(
          icon: Icon(Icons.search, color: context.theme.colorScheme.onBackground, size: 22),
          onPressed: ss.settings.redactedMode.value ? null : () => _openSearch(context),
        ),
      ),
      if (canRefresh || refreshing || refreshing2)
        Container(
          width: 48,
          height: 48,
          child: Container(
            width: 48,
            margin: const EdgeInsets.only(right: 8),
            child: refreshing || refreshing2
                ? buildProgressIndicator(context)
                : IconButton(
                    iconSize: 22,
                    icon: Icon(iOS ? CupertinoIcons.arrow_counterclockwise : Icons.refresh,
                        color: context.theme.colorScheme.onBackground, size: 22),
                    onPressed: _refreshManually,
                  ),
          ),
        ),
    ];

    return SliverAppBar(
      backgroundColor: headerColor,
      pinned: true,
      stretch: true,
      expandedHeight: context.height / 3,
      elevation: 0,
      automaticallyImplyLeading: false,
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          var expandRatio = (constraints.maxHeight - 50) / (context.height / 3 - 50);

          if (expandRatio > 1.0) expandRatio = 1.0;
          if (expandRatio < 0.0) expandRatio = 0.0;
          final animation = AlwaysStoppedAnimation<double>(expandRatio);

          return Stack(
            fit: StackFit.expand,
            children: [
              FadeTransition(
                opacity: Tween(begin: 0.0, end: 1.0).animate(CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0.3, 1.0, curve: Curves.easeIn),
                )),
                child: Center(
                    child: Text(title,
                        style: context.theme.textTheme.displaySmall!
                            .copyWith(color: context.theme.colorScheme.onBackground),
                        textAlign: TextAlign.center)),
              ),
              FadeTransition(
                opacity: Tween(begin: 1.0, end: 0.0).animate(CurvedAnimation(
                  parent: animation,
                  curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
                )),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Container(
                    padding: const EdgeInsets.only(left: 40),
                    height: 50,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        title,
                        style: context.theme.textTheme.titleLarge,
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 8.0),
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Container(
                    height: 50,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: buildBackButton(context),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomRight,
                child: Container(
                  height: 50,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: actions,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget buildMap() {
    var lastLocation = ss.settings.lastLocation.value?.split(",");
    var savedLocation = lastLocation != null ? LatLng(double.parse(lastLocation[0]), double.parse(lastLocation[1])) : const LatLng(0, 0);
    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialZoom: location == null ? 14.0 : 15.0,
        minZoom: 1.0,
        maxZoom: 18.0,
        initialCenter: location == null ? savedLocation : LatLng(location!.latitude, location!.longitude),
        onTap: (_, __) => popupController.hideAllPopups(),
        // Hide popup when the map is tapped.
        keepAlive: true,
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
        onMapReady: () {
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.bluebubbles.app',
        ),
        PopupMarkerLayer(
          options: PopupMarkerLayerOptions(
            onPopupEvent: (ev, m) async {
              if (m.isEmpty) return;
              final markerKey = (m.first.key as ValueKey?)?.value;
              if (markerKey is! String || !markerKey.startsWith('friend-') || fmfClient == null) return;
              final friend = friends.firstWhereOrNull((item) => _friendMarkerKey(item) == markerKey);
              if (friend?.id != null) {
                await api.selectFriend(config: pushService.state!.osConfig, client: fmfClient!, friend: friend!.id);
              }
            },
            popupController: popupController,
            markers: markers.values.toList(),
            popupDisplayOptions: PopupDisplayOptions(
              builder: (context, marker) {
                final ValueKey? key = marker.key as ValueKey?;
                if (key?.value == "current") return const SizedBox();
                final markerKey = key?.value;
                if (markerKey is String && markerKey.startsWith("device-")) {
                  final item = devices.firstWhereOrNull((e) => _deviceMarkerKey(e) == markerKey);
                  if (item == null) return const SizedBox();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 5.0),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: context.theme.colorScheme.properSurface.withOpacity(0.8),
                      ),
                      padding: const EdgeInsets.fromLTRB(10, 10, 0, 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(ss.settings.redactedMode.value ? _sectionForDevice(item).singularLabel : (item.name ?? "Unknown ${_sectionForDevice(item).singularLabel}"), style: context.theme.textTheme.labelLarge),
                              Text(ss.settings.redactedMode.value ? "Location" : (item.location?.latitude != null ? "${item.location?.latitude}, ${item.location?.longitude}" : ""),
                                  style: context.theme.textTheme.bodySmall),
                            ],
                          ),
                          if (item.location?.latitude != null && item.location?.longitude != null)
                          ButtonTheme(
                            minWidth: 1,
                            child: TextButton(
                              style: TextButton.styleFrom(
                                shape: const CircleBorder(),
                                backgroundColor: context.theme.colorScheme.primaryContainer,
                              ),
                              onPressed: () async {
                                await MapsLauncher.launchCoordinates(item.location!.latitude!, item.location!.longitude!);
                              },
                              child: const Icon(
                                  Icons.directions,
                                  size: 20
                              ),
                            ),
                          )
                        ],
                      )
                    ),
                  );
                } else if (markerKey is String && markerKey.startsWith('friend-')) {
                  final item = friends.firstWhereOrNull((e) => _friendMarkerKey(e) == markerKey);
                  if (item == null) return const SizedBox();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 5.0),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: context.theme.colorScheme.properSurface.withOpacity(0.8),
                      ),
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.handle?.displayName ?? item.title ?? "Unknown Person",
                              style: context.theme.textTheme.labelLarge),
                          Text(ss.settings.redactedMode.value ? "Location" : (item.longAddress ?? "No location found"), style: context.theme.textTheme.bodySmall),
                          if (item.lastUpdated != null && item.status != LocationStatus.live)
                            Text("Last updated ${buildDate(item.lastUpdated)}", style: context.theme.textTheme.bodySmall),
                          if (item.status != null)
                            Text("${item.status!.name.capitalize!} Location", style: context.theme.textTheme.bodySmall),
                        ],
                      ),
                    ),
                  );
                }
                return const SizedBox();
              },
            ),
          ),
        ),
      ],
    );
  }
}
