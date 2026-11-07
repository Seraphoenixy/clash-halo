/// Which dashboard cards the user wants on the home page.
///
/// The reference client keeps the same idea (`home_cards`) and it earns its
/// keep: the dashboard answers different questions for a user who only switches
/// nodes and for one who debugs TUN, and neither should have to scroll past the
/// other's cards.
///
/// What is stored is the *hidden* set, not the visible one. A card added in a
/// later version is then visible by default: storing the visible list would
/// silently hide every future card from anyone who had ever touched the switch.
library;

import 'package:halo_storage/halo_storage.dart';

enum HomeCard {
  node('当前节点'),
  traffic('实时流量'),
  exit('出口信息'),
  core('代理内核'),
  proxy('系统代理'),
  tun('TUN 模式'),
  status('运行信息');

  const HomeCard(this.label);
  final String label;

  static HomeCard? fromWire(String value) {
    for (final card in HomeCard.values) {
      if (card.name == value) return card;
    }
    return null;
  }
}

class HomeCards {
  const HomeCards(this.hidden);

  /// Cards the user switched off.
  final Set<HomeCard> hidden;

  static const storageKey = 'ui.homeCards';

  /// Everything on.
  static HomeCards get defaults => const HomeCards({});

  bool isVisible(HomeCard card) => !hidden.contains(card);

  HomeCards toggle(HomeCard card) => HomeCards({
    for (final item in HomeCard.values)
      if (item == card ? !hidden.contains(card) : hidden.contains(item)) item,
  });

  /// Reads the stored hidden set. Anything unrecognised (an id from a version
  /// that no longer has that card, a hand-edited row) is ignored rather than
  /// treated as a reason to hide something.
  static HomeCards load(SettingsRepository repo) {
    final raw = repo.getJson(storageKey);
    if (raw is! List) return defaults;
    final restored = <HomeCard>{};
    for (final entry in raw) {
      if (entry is! String) continue;
      final card = HomeCard.fromWire(entry);
      if (card != null) restored.add(card);
    }
    return HomeCards(restored);
  }

  void save(SettingsRepository repo) => repo.setJson(storageKey, [
    for (final card in HomeCard.values)
      if (hidden.contains(card)) card.name,
  ]);
}
