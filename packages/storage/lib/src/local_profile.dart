/// The migration that turns 本地 nodes into a real subscription row.
///
/// Split out so the id and the backfill rule live together and can be asserted
/// by a test that runs the migration on a hand-built v5 database.
library;

import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

/// Fixed id of the built-in 本地 subscription.
///
/// A literal, not a generated id: the migration has to be re-runnable and the
/// repositories need a stable handle, so a value derived from the current time
/// would create a second 本地 profile on every retry. `local` is also what the
/// CLI prints, so a script can address it without looking it up first.
const String kLocalProfileId = 'local';

/// Display name of the built-in local subscription.
const String kLocalProfileName = '本地';

/// Creates the local profile when it is missing and adopts every node that
/// still has no profile.
///
/// Returns the number of nodes adopted, which is 0 on a healthy database — this
/// is what makes the migration a no-op for anyone who never had local nodes.
int backfillLocalProfile(Database db) {
  final hasProfile = db.select(
    'SELECT id FROM ${Tables.subscriptions} WHERE id = ?',
    [kLocalProfileId],
  ).isNotEmpty;

  final orphans = db.select(
    'SELECT COUNT(*) AS c FROM ${Tables.nodes} WHERE profile_id IS NULL',
  );
  final orphanCount = (orphans.first['c'] as int?) ?? 0;

  // Nothing to do: no local nodes and the profile already exists. Creating an
  // empty 本地 subscription on a fresh database would put a row in the
  // subscription list that the user never asked for.
  if (hasProfile && orphanCount == 0) return 0;
  if (!hasProfile && orphanCount == 0) return 0;

  if (!hasProfile) {
    db.execute(
      'INSERT INTO ${Tables.subscriptions} '
      '(id, name, url, enabled, auto_update, interval_min, last_updated, '
      ' last_error, node_count, etag, created_at, sort_index, kind, group_id, '
      ' use_proxy) '
      "VALUES (?, ?, '', 1, 0, 1440, 0, NULL, ?, NULL, 0, 0, 'local', NULL, 0)",
      [kLocalProfileId, kLocalProfileName, orphanCount],
    );
  }

  db.execute(
    'UPDATE ${Tables.nodes} SET profile_id = ?, '
    "source = 'subscription' WHERE profile_id IS NULL",
    [kLocalProfileId],
  );
  db.execute(
    'UPDATE ${Tables.subscriptions} SET node_count = '
    '(SELECT COUNT(*) FROM ${Tables.nodes} WHERE profile_id = ?) WHERE id = ?',
    [kLocalProfileId, kLocalProfileId],
  );
  return orphanCount;
}
