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
            if (pagedCorrelation) {
              final pages = observed?['paged_pages_scanned'] as int;
              final changes = observed?['paged_changes_scanned'] as int;
              final pagedNormalizedPairs =
                  observed?['paged_normalized_semantic_match_pairs'] as int;
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
              }) {
                expect(
                  observed?[key],
                  inInclusiveRange(0, observed?['paged_chat_records'] as int),
                  reason: key,
                );
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
                  observed?['paged_other_style_records'] as int;
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
                'paged_other_style_records',
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
              expect(
                observed?['message_sender_sources'],
                inInclusiveRange(0, 8),
              );
            }
          } else {
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
              'paged_other_style_records',
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
