// Test-only contract for the schema-2 Chat1 route-field failure matrix.
// No live Apple operations, no network/native calls, no user data.
// Covers the frozen schema-1 11-field x 8-kind prefix, appended content-free
// detail counters, and Dart-side live-harness invariants.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

// Schema constants mirror rust/src/api/cloud_sync_chat1_correlation.rs:
// CHAT1_ROUTE_FAILURE_MATRIX_SCHEMA = 2. The first 88 slots remain the exact
// schema-1 row-major matrix; schema-2 appends 17 detail counters.
const int kFailureMatrixSchema = 2;
const int kFailureFieldCount = 11;
const int kFailureKindCount = 8;
const int kFailureMatrixBaseLen = 88;
const int kFailureMatrixDetailLen = 17;
const int kFailureMatrixLen = kFailureMatrixBaseLen + kFailureMatrixDetailLen;
const int kLahValidationBaseIndex = 46;
const int kPtcptsWireShapeBaseIndex = 65;

// Stable row order. Schema only, not user data.
const List<String> kFailureFields = <String>[
  'record_key',
  'cid',
  'gid',
  'ogid',
  'guid',
  'lah',
  'svc',
  'stl',
  'ptcpts',
  'prop',
  'cross_field',
];

// Stable column order. Schema only, not user data.
const List<String> kFailureKinds = <String>[
  'missing_value',
  'wire_shape',
  'key_selection',
  'ciphertext_key',
  'decrypt',
  'payload_decode',
  'validation',
  'cap',
];

// Stable append-only detail order. Categories never carry values, lengths,
// hashes, record identifiers, or ordering.
const List<String> kFailureDetails = <String>[
  'lah_string_value_absent',
  'lah_empty',
  'lah_too_long',
  'lah_trim_mismatch',
  'lah_control',
  'lah_other',
  'ptcpts_duplicate',
  'ptcpts_outer_empty_list',
  'ptcpts_outer_type',
  'ptcpts_outer_flag_absent',
  'ptcpts_outer_flag_true',
  'ptcpts_outer_payload',
  'ptcpts_entry_type',
  'ptcpts_entry_flag_absent',
  'ptcpts_entry_flag_false',
  'ptcpts_entry_payload',
  'ptcpts_other',
];

int matrixIndex(int fieldIdx, int kindIdx) =>
    fieldIdx * kFailureKindCount + kindIdx;

int decodeFieldIdx(int index) => index ~/ kFailureKindCount;
int decodeKindIdx(int index) => index % kFailureKindCount;

// Pure mirror of expectRouteFieldFailureMatrix in the live harness test.
void checkMatrix(
  List<int> matrix, {
  required int expectedSum,
  required String reason,
}) {
  expect(matrix, hasLength(kFailureMatrixLen), reason: reason + '_length');
  for (var i = 0; i < matrix.length; i++) {
    expect(
      matrix[i],
      greaterThanOrEqualTo(0),
      reason: reason + '_x' + i.toString(),
    );
  }
  final baseSum = matrix
      .take(kFailureMatrixBaseLen)
      .fold<int>(0, (sum, count) => sum + count);
  expect(baseSum, expectedSum, reason: reason + '_base_sum');
  final detailSum = matrix
      .skip(kFailureMatrixBaseLen)
      .fold<int>(0, (sum, count) => sum + count);
  expect(
    detailSum,
    matrix[kLahValidationBaseIndex] + matrix[kPtcptsWireShapeBaseIndex],
    reason: reason + '_detail_partition',
  );
}

void main() {
  test('schema 2 preserves the v1 11x8 prefix and appends detail', () {
    expect(kFailureMatrixSchema, 2);
    expect(kFailureFieldCount, 11);
    expect(kFailureKindCount, 8);
    expect(kFailureMatrixBaseLen, 88);
    expect(kFailureMatrixBaseLen, kFailureFieldCount * kFailureKindCount);
    expect(kFailureMatrixDetailLen, 17);
    expect(kFailureMatrixLen, 105);
    expect(kFailureFields, hasLength(kFailureFieldCount));
    expect(kFailureKinds, hasLength(kFailureKindCount));
    expect(kFailureDetails, hasLength(kFailureMatrixDetailLen));
  });
  test('row order is frozen record_key through cross_field', () {
    expect(kFailureFields.first, 'record_key');
    expect(kFailureFields.last, 'cross_field');
    expect(kFailureFields[8], 'ptcpts');
    expect(kFailureFields[9], 'prop');
    expect(kFailureFields.toSet(), hasLength(kFailureFieldCount));
  });
  test('column order is frozen missing_value through cap', () {
    expect(kFailureKinds.first, 'missing_value');
    expect(kFailureKinds.last, 'cap');
    expect(kFailureKinds[1], 'wire_shape');
    expect(kFailureKinds[5], 'payload_decode');
    expect(kFailureKinds.toSet(), hasLength(kFailureKindCount));
  });
  test('row-major index math covers all 88 cells uniquely', () {
    final seen = <int>{};
    for (var f = 0; f < kFailureFieldCount; f++) {
      for (var k = 0; k < kFailureKindCount; k++) {
        final idx = matrixIndex(f, k);
        expect(idx, f * kFailureKindCount + k);
        expect(idx, inInclusiveRange(0, kFailureMatrixBaseLen - 1));
        expect(seen.add(idx), isTrue);
        expect(decodeFieldIdx(idx), f);
        expect(decodeKindIdx(idx), k);
      }
    }
    expect(seen, hasLength(kFailureMatrixBaseLen));
  });
  test('spot cells pin row-major arithmetic', () {
    expect(matrixIndex(0, 0), 0, reason: 'record_key:missing_value');
    expect(matrixIndex(0, 7), 7, reason: 'record_key:cap');
    expect(matrixIndex(1, 0), 8, reason: 'cid:missing_value');
    expect(matrixIndex(10, 7), 87, reason: 'cross_field:cap');
    expect(matrixIndex(10, 0), 80, reason: 'cross_field:missing_value');
    expect(matrixIndex(8, 4), 68, reason: 'ptcpts:decrypt');
    expect(matrixIndex(9, 5), 77, reason: 'prop:payload_decode');
  });
  test('zeroed cached and paged matrices satisfy disabled-path sum', () {
    checkMatrix(
      List<int>.filled(kFailureMatrixLen, 0),
      expectedSum: 0,
      reason: 'cached_disabled',
    );
    checkMatrix(
      List<int>.filled(kFailureMatrixLen, 0),
      expectedSum: 0,
      reason: 'paged_disabled',
    );
    expect(kFailureMatrixSchema, 2, reason: 'schema_disabled');
    expect(Uint32List(kFailureMatrixLen), hasLength(kFailureMatrixLen));
  });
  test('each singleton cell attributes exactly one failure', () {
    for (var idx = 0; idx < kFailureMatrixBaseLen; idx++) {
      final matrix = List<int>.filled(kFailureMatrixLen, 0);
      matrix[idx] = 1;
      if (idx == kLahValidationBaseIndex) {
        matrix[kFailureMatrixBaseLen + 5] = 1;
      } else if (idx == kPtcptsWireShapeBaseIndex) {
        matrix[kFailureMatrixBaseLen + 16] = 1;
      }
      checkMatrix(matrix, expectedSum: 1, reason: 'cell' + idx.toString());
      expect(decodeFieldIdx(idx), idx ~/ kFailureKindCount);
      expect(decodeKindIdx(idx), idx % kFailureKindCount);
    }
  });
  test('each detail cell partitions exactly one matching base failure', () {
    for (var detail = 0; detail < kFailureMatrixDetailLen; detail++) {
      final matrix = List<int>.filled(kFailureMatrixLen, 0);
      final base = detail <= 5
          ? kLahValidationBaseIndex
          : kPtcptsWireShapeBaseIndex;
      matrix[base] = 1;
      matrix[kFailureMatrixBaseLen + detail] = 1;
      checkMatrix(matrix, expectedSum: 1, reason: 'detail' + detail.toString());
    }
  });
  test('multi-cell matrix sums across rows and columns', () {
    final matrix = List<int>.filled(kFailureMatrixLen, 0);
    matrix[matrixIndex(0, 0)] = 2;
    matrix[matrixIndex(1, 1)] = 3;
    matrix[matrixIndex(10, 7)] = 5;
    checkMatrix(matrix, expectedSum: 10, reason: 'multi_cell');
    var crossRow = 0;
    for (var k = 0; k < kFailureKindCount; k++) {
      crossRow += matrix[matrixIndex(10, k)];
    }
    expect(crossRow, 5, reason: 'cross_field_row');
  });
  test('generated DTO and native source retain matrix shape', () {
    final rust = File(
      'rust/src/api/cloud_sync_chat1_correlation.rs',
    ).readAsStringSync();
    expect(rust, contains('CHAT1_ROUTE_FAILURE_MATRIX_SCHEMA: u32 = 2'));
    expect(rust, contains('CHAT1_ROUTE_FAILURE_FIELD_COUNT: usize = 11'));
    expect(rust, contains('CHAT1_ROUTE_FAILURE_KIND_COUNT: usize = 8'));
    expect(rust, contains('CHAT1_ROUTE_FAILURE_DETAIL_COUNT: usize = 17'));
    expect(rust, contains('CHAT1_ROUTE_FAILURE_BASE_MATRIX_LEN'));
    expect(rust, contains('CHAT1_ROUTE_FAILURE_MATRIX_LEN'));
    expect(rust.indexOf('RecordKey = 0'), greaterThanOrEqualTo(0));
    expect(
      rust.indexOf('CrossField = 10'),
      greaterThan(rust.indexOf('RecordKey = 0')),
    );
    expect(rust.indexOf('MissingValue = 0'), greaterThanOrEqualTo(0));
    expect(
      rust.indexOf('Cap = 7'),
      greaterThan(rust.indexOf('MissingValue = 0')),
    );
    expect(rust, contains('route_field_failure_matrix_schema'));
    expect(rust, contains('paged_route_field_failure_matrix'));
    final dart = File(
      'lib/src/rust/api/cloud_sync_chat1_correlation.dart',
    ).readAsStringSync();
    expect(dart, contains('routeFieldFailureMatrixSchema'));
    expect(dart, contains('routeFieldFailureMatrix'));
    expect(dart, contains('pagedRouteFieldFailureMatrix'));
    final harness = File(
      'test/live/cloud_sync_v2_windows_live_harness_test.dart',
    ).readAsStringSync();
    expect(harness, contains('expectRouteFieldFailureMatrix'));
    expect(harness, contains('kChat1FailureMatrixDetailLen = 17'));
    expect(harness, contains('kChat1FailureMatrixBaseLen = 88'));
  });
}
