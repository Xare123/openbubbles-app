import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/cloud_sync_v2_windows_harness.dart' as harness;
import 'package:bluebubbles/database/database.dart';
import 'package:bluebubbles/services/backend/filesystem/filesystem_service.dart';
import 'package:bluebubbles/services/backend/filesystem/cloud_sync_windows_dev_profile.dart';
import 'package:bluebubbles/src/rust/api/api.dart' as api;
import 'package:bluebubbles/src/rust/frb_generated.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'cloud_sync_edit_echo_verification.dart';
import 'cloud_sync_chat1_discovery.dart';
import 'cloud_sync_parent_coverage.dart';

const int kChat1FailureMatrixSchema = 2;
const int kChat1FailureMatrixBaseLen = 88;
const int kChat1FailureMatrixDetailLen = 17;
const int kChat1FailureMatrixLen =
    kChat1FailureMatrixBaseLen + kChat1FailureMatrixDetailLen;
const int kChat1LahValidationBaseIndex = 46;
const int kChat1PtcptsWireShapeBaseIndex = 65;

void expectRouteFieldFailureMatrix(
  Object? value, {
  required int expectedSum,
  required String reason,
}) {
  final matrix = (value as List).cast<int>();
  expect(matrix, hasLength(kChat1FailureMatrixLen), reason: '${reason}_length');
  for (final count in matrix) {
    expect(count, greaterThanOrEqualTo(0), reason: reason);
  }
  final baseSum = matrix
      .take(kChat1FailureMatrixBaseLen)
      .fold<int>(0, (sum, count) => sum + count);
  expect(baseSum, expectedSum, reason: '${reason}_base_sum');
  final detailSum = matrix
      .skip(kChat1FailureMatrixBaseLen)
      .fold<int>(0, (sum, count) => sum + count);
  expect(
    detailSum,
    matrix[kChat1LahValidationBaseIndex] +
        matrix[kChat1PtcptsWireShapeBaseIndex],
    reason: '${reason}_detail_partition',
  );
}

void main() {
  final enabled =
      Platform.environment['OPENBUBBLES_RUN_LIVE_WINDOWS_HARNESS'] == '1';
  final operation =
      Platform.environment['OPENBUBBLES_LIVE_HARNESS_OPERATION'] ??
      'view-projection';
  final launchId = Platform.environment['OPENBUBBLES_LIVE_HARNESS_LAUNCH_ID'];
  var rustInitialized = false;
  var databaseOpen = false;

  setUpAll(() async {
    if (!enabled) return;
    if (Platform.environment['OPENBUBBLES_INSPECT_RETAINED'] == '1') {
      harness.cloudSyncV2RetainedInspectionOffset(
        Platform.environment['OPENBUBBLES_INSPECT_RETAINED_OFFSET'],
      );
    }
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('dev.fluttercommunity.plus/package_info'),
          (_) async => <String, Object?>{
            'appName': 'OpenBubbles Cloud Sync V2 Test Host',
            'packageName': 'com.bluebubbles.cloudsync.testhost',
            'version': '0.0.0',
            'buildNumber': '0',
            'buildSignature': '',
            'installerStore': null,
          },
        );
    if (launchId == null ||
        !harness.CloudSyncV2WindowsHarnessLaunch.isValidLaunchId(launchId)) {
      throw StateError('OPENBUBBLES_LIVE_HARNESS_LAUNCH_ID is required');
    }
    final nativeLibrary =
        Platform.environment['OPENBUBBLES_TEST_NATIVE_LIBRARY'];
    if (nativeLibrary == null) {
      throw StateError('OPENBUBBLES_TEST_NATIVE_LIBRARY is required');
    }
    harness.configureCloudSyncV2WindowsHarnessTestLaunch(launchId);
    fs.configureCloudSyncV2WindowsDevProfile();
    await RustLib.init(externalLibrary: ExternalLibrary.open(nativeLibrary));
    rustInitialized = true;
    await fs.init(headless: true);
    await Logger.init();
    await api.doFirstTimeInit(path: fs.appDocDir.path);
    await Database.init(cloudSyncV2Harness: true);
    databaseOpen = true;
  });

  tearDownAll(() {
    if (databaseOpen && !Database.store.isClosed()) Database.store.close();
    if (rustInitialized) RustLib.dispose();
  });

  testWidgets(
    'isolated Windows profile executes one explicit harness operation',
    (tester) async {
      const allowedOperations = <String>{
        'view-projection',
        'run-once',
        'drain',
        'local-write',
        'probe-message-feed',
        'inspect-edit-conflict',
        'inspect-retained',
        'inspect-chat-parents',
        'inspect-chat1-discovery',
      };
      expect(operation, isIn(allowedOperations));
      final harnessKey = GlobalKey<harness.CloudSyncV2WindowsHarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          home: harness.CloudSyncV2WindowsHarness(
            key: harnessKey,
            autoStart: false,
            operation: harness.CloudSyncV2WindowsHarnessOperation.values
                .singleWhere(
                  (candidate) => switch (operation) {
                    'inspect-edit-conflict' =>
                      candidate ==
                          harness
                              .CloudSyncV2WindowsHarnessOperation
                              .interactive,
                    'inspect-retained' =>
                      candidate ==
                          harness
                              .CloudSyncV2WindowsHarnessOperation
                              .interactive,
                    'inspect-chat-parents' =>
                      candidate ==
                          harness
                              .CloudSyncV2WindowsHarnessOperation
                              .interactive,
                    'inspect-chat1-discovery' =>
                      candidate ==
                          harness
                              .CloudSyncV2WindowsHarnessOperation
                              .interactive,
                    'view-projection' =>
                      candidate ==
                          harness
                              .CloudSyncV2WindowsHarnessOperation
                              .projectionViewer,
                    'run-once' =>
                      candidate ==
                          harness.CloudSyncV2WindowsHarnessOperation.runOnce,
                    'drain' =>
                      candidate ==
                          harness.CloudSyncV2WindowsHarnessOperation.drain,
                    'local-write' =>
                      candidate ==
                          harness.CloudSyncV2WindowsHarnessOperation.localWrite,
                    'probe-message-feed' =>
                      candidate ==
                          harness
                              .CloudSyncV2WindowsHarnessOperation
                              .messageFeedProbe,
                    _ => false,
                  },
                ),
          ),
        ),
      );
      await tester.runAsync(
        () => harnessKey.currentState!.initializeForTestHost(),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );

      final profile = CloudSyncWindowsDevProfile.requireBootstrapped();
      final statusFile = File(
        path.join(profile.path, 'cloud-sync-v2', 'windows-harness-status.json'),
      );
      expect(statusFile.existsSync(), isTrue);
      final decoded = jsonDecode(statusFile.readAsStringSync());
      expect(decoded, isA<Map<String, dynamic>>());
      final status = (decoded as Map<String, dynamic>).cast<String, Object?>();
      expect(status['launch_id'], launchId);
      if (Platform.environment['OPENBUBBLES_VERIFY_EDIT_CLAIM']
          case final requestId?) {
        final proof = await tester.runAsync(
          () => harnessKey.currentState!.observeEditEchoForTestHost(
            (auth, pause) => verifyEditEcho(
              store: Database.store,
              profile: profile,
              requestId: requestId,
              auth: auth,
              pauseToken: pause,
            ),
          ),
        );
        debugPrint('windows_edit_echo_proof=${jsonEncode(proof)}');
        expect(proof?['exact_current_text'], isTrue);
        expect(proof?['exact_edit_text_and_milliseconds'], isTrue);
        expect(proof?['local_history_unchanged'], isTrue);
        expect(proof?['exact_retracted_parts'], isTrue);
        if (Platform.environment['OPENBUBBLES_VERIFY_CHAIN_UNSEND'] == '1') {
          expect(proof?['local_edit_count'], 3);
          expect(proof?['native_edit_count'], 3);
          expect(proof?['retracted_part_count'], 1);
        }
      }
      if (Platform.environment['OPENBUBBLES_MATERIALIZE_RETAINED_BODY'] == '1') {
        final bodied = await tester.runAsync<Map<String, Object?>>(
          () => harnessKey.currentState!.materializeRetainedBodyForTestHost(),
        );
        debugPrint('windows_retained_body=' + jsonEncode(bodied));
        expect(bodied?['completed'], isTrue);
      }
      if (Platform.environment['OPENBUBBLES_INSPECT_RETAINED'] == '1') {
        final observed = await tester.runAsync<Map<String, Object?>>(
          () => harnessKey.currentState!.inspectRetainedForTestHost(),
        );
        debugPrint('windows_retained_observation=${jsonEncode(observed)}');
        expect(observed?['durable_state_unchanged'], isTrue);
      }
      if (Platform.environment['OPENBUBBLES_INSPECT_CHAT_PARENTS'] == '1') {
        expect(operation, 'inspect-chat-parents');
        final observed = await tester.runAsync(
          () => harnessKey.currentState!.observeChatParentsForTestHost(
            (auth, pause) => observeCachedParentCoverage(
              store: Database.store,
              profile: profile,
              auth: auth,
              pauseToken: pause as BigInt,
            ),
          ),
        );
        debugPrint('windows_parent_coverage=${jsonEncode(observed)}');
        expect(observed?['durable_state_unchanged'], isTrue);
      }
      if (Platform.environment['OPENBUBBLES_INSPECT_CHAT1_DISCOVERY'] == '1') {
        expect(operation, 'inspect-chat1-discovery');
        final observed = await tester.runAsync<Map<String, Object?>>(
          () => harnessKey.currentState!.observeChat1DiscoveryForTestHost((
            auth,
            pause,
            readCurrentBoundAuth,
          ) async {
            if (Platform.environment['OPENBUBBLES_INSPECT_CHAT1_CORRELATION'] ==
                '1') {
              return correlateCachedChat1Routes(
                store: Database.store,
                profile: profile,
                auth: auth,
                pauseToken: pause,
                readCurrentBoundAuth: readCurrentBoundAuth,
              );
            }
            if (Platform.environment['OPENBUBBLES_INSPECT_CHAT1_CACHE_ONLY'] ==
                '1') {
              return inspectCachedChat1Journal(
                store: Database.store,
                auth: auth,
              );
            }
            return observeChat1Discovery(
              store: Database.store,
              profile: profile,
              auth: auth,
              pauseToken: pause,
              readCurrentBoundAuth: readCurrentBoundAuth,
            );
          }),
        );
        debugPrint('windows_chat1_discovery=${jsonEncode(observed)}');
        expect(observed?['account_bound'], isTrue);
        if (Platform.environment['OPENBUBBLES_INSPECT_CHAT1_CORRELATION'] ==
            '1') {
          if (Platform.environment['OPENBUBBLES_EXPORT_CHAT1_INPUT_MANIFEST'] ==
              '1') {
            expect(observed?['network_read_performed'], isFalse);
            expect(observed?['content_exposed'], isFalse);
            expect(observed?['durable_state_unchanged'], isTrue);
            expect(observed?['manifest_exported'], isTrue);
            expect(observed?['message_sources'], 8);
            expect(
              observed?['anchor_message_sources'],
              inInclusiveRange(8, 2048),
            );
            expect(observed?['chat1_sources'], 50);
            expect(observed?['anchor_source_budget_exhausted'], isA<bool>());
            return;
          }
          final semanticCorrelation =
              Platform
                  .environment['OPENBUBBLES_INSPECT_CHAT1_SEMANTIC_CORRELATION'] ==
              '1';
          final pagedCorrelation =
              Platform
                  .environment['OPENBUBBLES_INSPECT_CHAT1_PAGED_CORRELATION'] ==
              '1';
          expect(pagedCorrelation && !semanticCorrelation, isFalse);
          expect(observed?['network_read_performed'], semanticCorrelation);
          expect(observed?['content_exposed'], isFalse);
          expect(observed?['durable_state_unchanged'], isTrue);
          expect(observed?['completed'], isTrue);
          expect(observed?['message_sources'], 8);
          expect(observed?['decoded_message_routes'], 8);
          final anchorSources = observed?['anchor_message_sources'] as int;
          final decodedAnchors = observed?['decoded_anchor_messages'] as int;
          final skippedAnchors = observed?['skipped_anchor_messages'] as int;
          final distinctAnchorGuids =
              observed?['distinct_anchor_message_guids'] as int;
          final conflictingAnchorGuids =
              observed?['conflicting_anchor_message_guids'] as int;
          expect(anchorSources, inInclusiveRange(8, 2048));
          expect(decodedAnchors + skippedAnchors, anchorSources);
          expect(
            distinctAnchorGuids + conflictingAnchorGuids,
            lessThanOrEqualTo(decodedAnchors),
          );
          expect(observed?['anchor_source_budget_exhausted'], isA<bool>());
          expect(observed?['chat1_sources'], 50);
          expect(observed?['verified_chat1_records'], 50);
          expect(observed?['failure_code'], isNull);
          expect(
            observed?['semantic_correlation_requested'],
            semanticCorrelation,
          );
          expect(observed?['pcs_lookup_attempted'], semanticCorrelation);
          expect(observed?['paged_correlation_requested'], pagedCorrelation);
          if (semanticCorrelation) {
            final chatTypes = observed?['chat_record_type_records'] as int;
            final otherTypes = observed?['other_record_type_records'] as int;
            final decoded = observed?['decoded_route_records'] as int;
            final recordFailures = observed?['record_decode_failures'] as int;
            final fieldFailures =
                observed?['route_field_decode_failures'] as int;
            final failureMatrixSchema =
                observed?['route_field_failure_matrix_schema'] as int;
            expect(failureMatrixSchema, kChat1FailureMatrixSchema);
            expectRouteFieldFailureMatrix(
              observed?['route_field_failure_matrix'],
              expectedSum: fieldFailures,
              reason: 'route_field_failure_matrix',
            );
            final semanticPairs = observed?['semantic_match_pairs'] as int;
            expect(chatTypes + otherTypes, 50);
            expect(decoded + recordFailures + fieldFailures, chatTypes);
            expect(
              (observed?['chat_identifier_match_pairs'] as int) +
                  (observed?['group_id_match_pairs'] as int) +
                  (observed?['original_group_id_match_pairs'] as int) +
                  (observed?['guid_match_pairs'] as int),
              semanticPairs,
            );
            expect(
              observed?['matched_semantic_message_routes'],
              inInclusiveRange(0, 8),
            );
            expect(
              observed?['matched_semantic_chat1_records'],
              inInclusiveRange(0, decoded),
            );
            for (final key in <String>{
              'route_participant_match_pairs',
              'route_legacy_match_pairs',
              'route_lah_match_pairs',
              'msgproto_chat_identifier_match_pairs',
              'msgproto_group_id_match_pairs',
              'msgproto_original_group_id_match_pairs',
              'msgproto_guid_match_pairs',
              'msgproto_legacy_match_pairs',
              'sender_participant_match_pairs',
              'sender_lah_match_pairs',
            }) {
              expect(
                observed?[key],
                inInclusiveRange(0, decoded * 8),
                reason: key,
              );
            }
            for (final key in <String>{
              'matched_route_extra_message_routes',
              'matched_msgproto_targets',
              'matched_sender_targets',
            }) {
              expect(observed?[key], inInclusiveRange(0, 8), reason: key);
            }
            for (final key in <String>{
              'matched_route_extra_chat1_records',
              'matched_msgproto_chat1_records',
              'matched_sender_chat1_records',
              'participant_present_records',
              'legacy_present_records',
              'lah_present_records',
              'service_present_records',
              'imessage_service_records',
              'other_service_records',
              'style_direct_records',
              'style_group_records',
              'style_other_records',
            }) {
              expect(observed?[key], inInclusiveRange(0, decoded), reason: key);
            }
            expect(
              (observed?['imessage_service_records'] as int) +
                  (observed?['other_service_records'] as int),
              observed?['service_present_records'],
            );
            expect(
              (observed?['style_direct_records'] as int) +
                  (observed?['style_group_records'] as int) +
                  (observed?['style_other_records'] as int),
              lessThanOrEqualTo(decoded),
            );
            if (pagedCorrelation) {
              final pages = observed?['paged_pages_scanned'] as int;
              final changes = observed?['paged_changes_scanned'] as int;
              final pagedFieldFailures =
                  observed?['paged_route_field_decode_failures'] as int;
              final pagedNormalizedPairs =
                  observed?['paged_normalized_semantic_match_pairs'] as int;
              expectRouteFieldFailureMatrix(
                observed?['paged_route_field_failure_matrix'],
                expectedSum: pagedFieldFailures,
                reason: 'paged_route_field_failure_matrix',
              );
              expect(pages, inInclusiveRange(1, 20));
              expect(changes, inInclusiveRange(1, 1000));
              expect(
                observed?['paged_matched_message_routes'],
                inInclusiveRange(0, 8),
              );
              expect(
                observed?['paged_matched_chat1_records'] as int,
                lessThanOrEqualTo(observed?['paged_chat_records'] as int),
              );
              expect(
                (observed?['paged_normalized_chat_identifier_match_pairs']
                        as int) +
                    (observed?['paged_normalized_group_id_match_pairs']
                        as int) +
                    (observed?['paged_normalized_original_group_id_match_pairs']
                        as int) +
                    (observed?['paged_normalized_guid_match_pairs'] as int),
                pagedNormalizedPairs,
              );
              expect(
                observed?['paged_normalized_matched_message_routes'],
                inInclusiveRange(0, 8),
              );
              expect(
                observed?['paged_normalized_matched_chat1_records'] as int,
                lessThanOrEqualTo(observed?['paged_chat_records'] as int),
              );
              expect(
                (observed?['paged_terminal_reached'] as bool) ||
                    (observed?['paged_budget_exhausted'] as bool) ||
                    observed?['paged_matched_message_routes'] == 8 ||
                    observed?['paged_normalized_matched_message_routes'] == 8,
                isTrue,
              );
              for (final key in <String>{
                'paged_route_participant_match_pairs',
                'paged_route_legacy_match_pairs',
                'paged_route_lah_match_pairs',
                'paged_msgproto_chat_identifier_match_pairs',
                'paged_msgproto_group_id_match_pairs',
                'paged_msgproto_original_group_id_match_pairs',
                'paged_msgproto_guid_match_pairs',
                'paged_msgproto_legacy_match_pairs',
                'paged_sender_participant_match_pairs',
                'paged_sender_lah_match_pairs',
                'paged_last_seen_target_message_match_pairs',
                'paged_last_seen_anchor_exact_match_pairs',
                'paged_last_seen_anchor_normalized_match_pairs',
                'paged_sender_service_style_match_pairs',
                'paged_normalized_route_participant_match_pairs',
                'paged_normalized_route_legacy_match_pairs',
                'paged_normalized_route_lah_match_pairs',
                'paged_normalized_msgproto_chat_identifier_match_pairs',
                'paged_normalized_msgproto_group_id_match_pairs',
                'paged_normalized_msgproto_original_group_id_match_pairs',
                'paged_normalized_msgproto_guid_match_pairs',
                'paged_normalized_msgproto_legacy_match_pairs',
                'paged_normalized_sender_participant_match_pairs',
                'paged_normalized_sender_lah_match_pairs',
              }) {
                expect(
                  observed?[key],
                  inInclusiveRange(0, changes * 8),
                  reason: key,
                );
              }
              for (final key in <String>{
                'paged_matched_route_extra_message_routes',
                'paged_matched_msgproto_targets',
                'paged_matched_sender_targets',
                'paged_normalized_matched_route_extra_message_routes',
                'paged_normalized_matched_msgproto_targets',
                'paged_normalized_matched_sender_targets',
                'paged_matched_last_seen_target_messages',
                'paged_matched_anchor_exact_targets',
                'paged_matched_anchor_normalized_targets',
                'paged_matched_sender_service_style_targets',
              }) {
                expect(observed?[key], inInclusiveRange(0, 8), reason: key);
              }
              for (final key in <String>{
                'paged_matched_route_extra_chat1_records',
                'paged_matched_msgproto_chat1_records',
                'paged_matched_sender_chat1_records',
                'paged_normalized_matched_route_extra_chat1_records',
                'paged_normalized_matched_msgproto_chat1_records',
                'paged_normalized_matched_sender_chat1_records',
                'paged_last_seen_message_guid_present_records',
                'paged_matched_last_seen_target_chat1_records',
                'paged_matched_anchor_exact_chat1_records',
                'paged_matched_anchor_normalized_chat1_records',
                'paged_matched_sender_service_style_chat1_records',
              }) {
                expect(
                  observed?[key],
                  inInclusiveRange(0, observed?['paged_chat_records'] as int),
                  reason: key,
                );
              }
              for (final prefix in <String>{
                'paged_sender_service_style',
                'paged_last_seen_target',
                'paged_anchor_exact',
                'paged_anchor_normalized',
              }) {
                final zero =
                    observed?['${prefix}_zero_candidate_targets'] as int;
                final unique =
                    observed?['${prefix}_unique_candidate_targets'] as int;
                final multiple =
                    observed?['${prefix}_multiple_candidate_targets'] as int;
                expect(zero + unique + multiple, 8, reason: prefix);
              }
              final messageGroupIdSources =
                  observed?['message_group_id_sources'] as int;
              final messageSenderSources =
                  observed?['message_sender_sources'] as int;
              expect(messageGroupIdSources, inInclusiveRange(0, 8));
              expect(messageSenderSources, inInclusiveRange(0, 8));
              expect(
                messageGroupIdSources,
                lessThanOrEqualTo(observed?['decoded_message_routes'] as int),
              );
              expect(
                messageSenderSources,
                lessThanOrEqualTo(observed?['decoded_message_routes'] as int),
              );
              final pagedImessageService =
                  observed?['paged_imessage_service_records'] as int;
              final pagedOtherService =
                  observed?['paged_other_service_records'] as int;
              final pagedDirectStyle =
                  observed?['paged_style_direct_records'] as int;
              final pagedGroupStyle =
                  observed?['paged_style_group_records'] as int;
              final pagedOtherStyle =
                  observed?['paged_style_other_records'] as int;
              expect(pagedImessageService, inInclusiveRange(0, changes));
              expect(pagedOtherService, inInclusiveRange(0, changes));
              expect(pagedDirectStyle, inInclusiveRange(0, changes));
              expect(pagedGroupStyle, inInclusiveRange(0, changes));
              expect(pagedOtherStyle, inInclusiveRange(0, changes));
              expect(
                pagedImessageService + pagedOtherService,
                observed?['paged_service_present_records'],
              );
              expect(
                pagedDirectStyle + pagedGroupStyle + pagedOtherStyle,
                lessThanOrEqualTo(changes),
              );
            } else {
              expectRouteFieldFailureMatrix(
                observed?['paged_route_field_failure_matrix'],
                expectedSum: 0,
                reason: 'paged_route_field_failure_matrix_disabled',
              );
              for (final key in <String>{
                'paged_normalized_chat_identifier_match_pairs',
                'paged_normalized_group_id_match_pairs',
                'paged_normalized_original_group_id_match_pairs',
                'paged_normalized_guid_match_pairs',
                'paged_normalized_semantic_match_pairs',
                'paged_normalized_matched_message_routes',
                'paged_normalized_matched_chat1_records',
                'paged_route_participant_match_pairs',
                'paged_route_legacy_match_pairs',
                'paged_route_lah_match_pairs',
                'paged_msgproto_chat_identifier_match_pairs',
                'paged_msgproto_group_id_match_pairs',
                'paged_msgproto_original_group_id_match_pairs',
                'paged_msgproto_guid_match_pairs',
                'paged_msgproto_legacy_match_pairs',
                'paged_sender_participant_match_pairs',
                'paged_sender_lah_match_pairs',
                'paged_matched_route_extra_message_routes',
                'paged_matched_route_extra_chat1_records',
                'paged_matched_msgproto_targets',
                'paged_matched_msgproto_chat1_records',
                'paged_matched_sender_targets',
                'paged_matched_sender_chat1_records',
                'paged_participant_present_records',
                'paged_legacy_present_records',
                'paged_lah_present_records',
                'paged_service_present_records',
                'paged_imessage_service_records',
                'paged_other_service_records',
                'paged_style_direct_records',
                'paged_style_group_records',
                'paged_style_other_records',
                'paged_normalized_route_participant_match_pairs',
                'paged_normalized_route_legacy_match_pairs',
                'paged_normalized_route_lah_match_pairs',
                'paged_normalized_msgproto_chat_identifier_match_pairs',
                'paged_normalized_msgproto_group_id_match_pairs',
                'paged_normalized_msgproto_original_group_id_match_pairs',
                'paged_normalized_msgproto_guid_match_pairs',
                'paged_normalized_msgproto_legacy_match_pairs',
                'paged_normalized_sender_participant_match_pairs',
                'paged_normalized_sender_lah_match_pairs',
                'paged_normalized_matched_route_extra_message_routes',
                'paged_normalized_matched_route_extra_chat1_records',
                'paged_normalized_matched_msgproto_targets',
                'paged_normalized_matched_msgproto_chat1_records',
                'paged_normalized_matched_sender_targets',
                'paged_normalized_matched_sender_chat1_records',
                'paged_last_seen_message_guid_present_records',
                'paged_last_seen_target_message_match_pairs',
                'paged_matched_last_seen_target_messages',
                'paged_matched_last_seen_target_chat1_records',
                'paged_last_seen_anchor_exact_match_pairs',
                'paged_matched_anchor_exact_targets',
                'paged_matched_anchor_exact_chat1_records',
                'paged_last_seen_anchor_normalized_match_pairs',
                'paged_matched_anchor_normalized_targets',
                'paged_matched_anchor_normalized_chat1_records',
                'paged_sender_service_style_match_pairs',
                'paged_matched_sender_service_style_targets',
                'paged_matched_sender_service_style_chat1_records',
                'paged_sender_service_style_zero_candidate_targets',
                'paged_sender_service_style_unique_candidate_targets',
                'paged_sender_service_style_multiple_candidate_targets',
                'paged_last_seen_target_zero_candidate_targets',
                'paged_last_seen_target_unique_candidate_targets',
                'paged_last_seen_target_multiple_candidate_targets',
                'paged_anchor_exact_zero_candidate_targets',
                'paged_anchor_exact_unique_candidate_targets',
                'paged_anchor_exact_multiple_candidate_targets',
                'paged_anchor_normalized_zero_candidate_targets',
                'paged_anchor_normalized_unique_candidate_targets',
                'paged_anchor_normalized_multiple_candidate_targets',
              }) {
                expect(observed?[key], 0, reason: key);
              }
              expect(
                observed?['message_group_id_sources'],
                inInclusiveRange(0, 8),
              );
              expect(
                observed?['message_sender_sources'],
                inInclusiveRange(0, 8),
              );
            }
          } else {
            expect(
              observed?['route_field_failure_matrix_schema'],
              kChat1FailureMatrixSchema,
            );
            expectRouteFieldFailureMatrix(
              observed?['route_field_failure_matrix'],
              expectedSum: 0,
              reason: 'route_field_failure_matrix_disabled',
            );
            expectRouteFieldFailureMatrix(
              observed?['paged_route_field_failure_matrix'],
              expectedSum: 0,
              reason: 'paged_route_field_failure_matrix_disabled',
            );
            for (final key in <String>{
              'chat_record_type_records',
              'other_record_type_records',
              'decoded_route_records',
              'record_decode_failures',
              'route_field_decode_failures',
              'chat_identifier_match_pairs',
              'group_id_match_pairs',
              'original_group_id_match_pairs',
              'guid_match_pairs',
              'semantic_match_pairs',
              'matched_semantic_message_routes',
              'matched_semantic_chat1_records',
              'paged_normalized_chat_identifier_match_pairs',
              'paged_normalized_group_id_match_pairs',
              'paged_normalized_original_group_id_match_pairs',
              'paged_normalized_guid_match_pairs',
              'paged_normalized_semantic_match_pairs',
              'paged_normalized_matched_message_routes',
              'paged_normalized_matched_chat1_records',
              'paged_route_participant_match_pairs',
              'paged_route_legacy_match_pairs',
              'paged_route_lah_match_pairs',
              'paged_msgproto_chat_identifier_match_pairs',
              'paged_msgproto_group_id_match_pairs',
              'paged_msgproto_original_group_id_match_pairs',
              'paged_msgproto_guid_match_pairs',
              'paged_msgproto_legacy_match_pairs',
              'paged_sender_participant_match_pairs',
              'paged_sender_lah_match_pairs',
              'paged_matched_route_extra_message_routes',
              'paged_matched_route_extra_chat1_records',
              'paged_matched_msgproto_targets',
              'paged_matched_msgproto_chat1_records',
              'paged_matched_sender_targets',
              'paged_matched_sender_chat1_records',
              'paged_participant_present_records',
              'paged_legacy_present_records',
              'paged_lah_present_records',
              'paged_service_present_records',
              'paged_imessage_service_records',
              'paged_other_service_records',
              'paged_style_direct_records',
              'paged_style_group_records',
              'paged_style_other_records',
              'paged_normalized_route_participant_match_pairs',
              'paged_normalized_route_legacy_match_pairs',
              'paged_normalized_route_lah_match_pairs',
              'paged_normalized_msgproto_chat_identifier_match_pairs',
              'paged_normalized_msgproto_group_id_match_pairs',
              'paged_normalized_msgproto_original_group_id_match_pairs',
              'paged_normalized_msgproto_guid_match_pairs',
              'paged_normalized_msgproto_legacy_match_pairs',
              'paged_normalized_sender_participant_match_pairs',
              'paged_normalized_sender_lah_match_pairs',
              'paged_normalized_matched_route_extra_message_routes',
              'paged_normalized_matched_route_extra_chat1_records',
              'paged_normalized_matched_msgproto_targets',
              'paged_normalized_matched_msgproto_chat1_records',
              'paged_normalized_matched_sender_targets',
              'paged_normalized_matched_sender_chat1_records',
            }) {
              expect(observed?[key], 0, reason: key);
            }
            expect(
              observed?['message_group_id_sources'],
              inInclusiveRange(0, 8),
            );
            expect(observed?['message_sender_sources'], inInclusiveRange(0, 8));
          }
        } else if (Platform
                .environment['OPENBUBBLES_INSPECT_CHAT1_CACHE_ONLY'] ==
            '1') {
          expect(observed?['network_read_performed'], isFalse);
        } else {
          expect(observed?['zero_mutation_counters'], isTrue);
          expect(observed?['canonical_counts_unchanged'], isTrue);
          expect(observed?['outbox_count_unchanged'], isTrue);
        }
      }
      if (Platform.environment['OPENBUBBLES_INSPECT_EDIT_CONFLICT'] == '1') {
        final comparison = await tester.runAsync(
          () => harnessKey.currentState!.inspectEditConflictForTestHost(),
        );
        debugPrint(
          'windows_edit_conflict_comparison=${jsonEncode(comparison)}',
        );
        if (Platform.environment['OPENBUBBLES_EDIT_CONFLICT_COPY'] != null) {
          expect(comparison?['copy_recovery_rejected'], isNot(true));
          final proof = comparison?['copy_replay'] as Map<String, Object?>?;
          expect(proof, isNotNull);
          expect(proof?['production_recovery'], isTrue);
          expect(proof?['disposition'], 'applied');
          expect(proof?['local_history_preserved'], isTrue);
          expect(proof?['original_inbox_status'], 2);
        }
      }
      if (status['safe_code'] == 'cloud_sync_native_auth_refresh_failed' &&
          Platform.environment['OPENBUBBLES_DIAGNOSE_READ_AUTH'] == '1') {
        final diagnostic = await tester.runAsync(
          () =>
              harnessKey.currentState!.diagnoseReadAuthenticationForTestHost(),
        );
        debugPrint('windows_read_auth_diagnostic=$diagnostic');
      }
      expect(
        status['state'],
        anyOf('finished', 'ready'),
        reason: jsonEncode(status),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
