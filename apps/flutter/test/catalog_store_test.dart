import 'dart:io';

import 'package:halo/src/state/catalog_store.dart';
import 'package:halo_storage/halo_storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late HaloStore store;
  late CatalogStore catalog;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('halo_catalog_test');
    final opened = HaloStore.open('${dir.path}${Platform.pathSeparator}db.sqlite');
    expect(opened.store, isNotNull, reason: '${opened.error}');
    store = opened.store!;
    catalog = CatalogStore()..attach(store);
  });

  tearDown(() {
    store.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {
      // A lingering WAL file can keep the directory busy on Windows.
    }
  });

  test('reads are cached until invalidate', () {
    final first = catalog.loadNodes();
    final again = catalog.loadNodes();
    expect(identical(first, again), isTrue,
        reason: 'build must not re-query on every frame');

    catalog.invalidate();
    expect(identical(catalog.loadNodes(), first), isFalse);
  });

  test('a closed store yields empty reads instead of throwing', () {
    final empty = CatalogStore();
    expect(empty.loadNodes(), isEmpty);
    expect(empty.loadProfiles(), isEmpty);
    expect(empty.loadGroups(), isEmpty);
    expect(empty.nodeByIdOrNull('n_x'), isNull);
    expect(() => empty.nodeRepo, throwsStateError);
  });

  test('ensureLocalProfile creates 本地 once and invalidates the cache', () {
    final created = catalog.ensureLocalProfile();
    expect(created.name, '本地');
    // The cache read after creation must see the row, and a second call must
    // return the same profile instead of creating another.
    expect(catalog.loadProfiles().any((p) => p.id == created.id), isTrue);
    final again = catalog.ensureLocalProfile();
    expect(again.id, created.id);
    expect(catalog.loadProfiles().where((p) => p.name == '本地'), hasLength(1));
  });
}
