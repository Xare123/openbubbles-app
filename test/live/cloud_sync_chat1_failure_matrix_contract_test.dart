// Test-only contract for the schema-1 Chat1 route-field failure matrix.
// No live Apple operations, no network/native calls, no user data.
// Covers the frozen 11-field x 8-kind row-major matrix and the Dart-side
// invariants mirrored in cloud_sync_v2_windows_live_harness_test.dart.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

// Schema constants mirror rust/src/api/cloud_sync_chat1_correlation.rs:
// CHAT1_ROUTE_FAILURE_MATRIX_SCHEMA = 1, FIELD_COUNT = 11, KIND_COUNT = 8.
const int kFailureMatrixSchema = 1;
const int kFailureFieldCount = 11;
const int kFailureKindCount = 8;
const int kFailureMatrixLen = 88;

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

int matrixIndex(int fieldIdx, int kindIdx) =>
    fieldIdx * kFailureKindCount + kindIdx;

int decodeFieldIdx(int index) => index ~/ kFailureKindCount;
int decodeKindIdx(int index) => index % kFailureKindCount;

int matrixSum(List<int> matrix) =>
    matrix.fold<int>(0, (sum, count) => sum + count);

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
  expect(matrixSum(matrix), expectedSum, reason: reason + '_sum');
}

void main() {
  test('schema and dimensions are frozen at v1 11x8', () {
    expect(kFailureMatrixSchema, 1);
    expect(kFailureFieldCount, 11);
    expect(kFailureKindCount, 8);
    expect(kFailureMatrixLen, 88);
    expect(kFailureMatrixLen, kFailureFieldCount * kFailureKindCount);
    expect(kFailureFields, hasLength(kFailureFieldCount));
    expect(kFailureKinds, hasLength(kFailureKindCount));
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
        expect(idx, inInclusiveRange(0, kFailureMatrixLen - 1));
        expect(seen.add(idx), isTrue);
        expect(decodeFieldIdx(idx), f);
        expect(decodeKindIdx(idx), k);
      }
    }
    expect(seen, hasLength(kFailureMatrixLen));
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
    expect(kFailureMatrixSchema, 1, reason: 'schema_disabled');
    expect(Uint32List(kFailureMatrixLen), hasLength(kFailureMatrixLen));
  });
  test('each singleton cell attributes exactly one failure', () {
    for (var idx = 0; idx < kFailureMatrixLen; idx++) {
      final matrix = List<int>.filled(kFailureMatrixLen, 0);
      matrix[idx] = 1;
      checkMatrix(matrix, expectedSum: 1, reason: 'cell' + idx.toString());
      expect(decodeFieldIdx(idx), idx ~/ kFailureKindCount);
      expect(decodeKindIdx(idx), idx % kFailureKindCount);
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
    expect(rust, contains('CHAT1_ROUTE_FAILURE_MATRIX_SCHEMA: u32 = 1'));
    expect(rust, contains('CHAT1_ROUTE_FAILURE_FIELD_COUNT: usize = 11'));
    expect(rust, contains('CHAT1_ROUTE_FAILURE_KIND_COUNT: usize = 8'));
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
    expect(harness, contains('hasLength(88)'));
  });
}
