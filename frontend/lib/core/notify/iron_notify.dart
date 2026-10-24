import 'dart:async';

import 'package:flutter/foundation.dart';

import 'iron_notice.dart';

/// Cola de avisos de la app: uno visible a la vez y los demás esperan por
/// prioridad. Se usa desde cualquier sitio sin `BuildContext`:
/// `IronNotify.show(IronNotice(kind: NoticeKind.success, title: '...'))`.
/// `IronNotifyHost` (en `main.dart`) lo dibuja según la plataforma.
class IronNotify extends ChangeNotifier {
  IronNotify._();

  static final IronNotify instance = IronNotify._();

  static void show(IronNotice notice) => instance.add(notice);

  static void dismiss(String id) => instance.remove(id);

  /// Avisos en espera como mucho; si llegan más, se pierden los de menor
  /// prioridad.
  static const maxQueued = 5;

  IronNotice? _current;
  final List<_Queued> _queue = [];
  Timer? _timer;
  DateTime? _startedAt;
  Duration _budget = Duration.zero;
  bool _paused = false;

  IronNotice? get current => _current;
  List<IronNotice> get queued => [for (final q in _queue) q.notice];
  bool get paused => _paused;

  /// Reloj del temporizador; las pruebas lo cambian por el del tiempo
  /// simulado.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// Tiempo que le queda al aviso visible.
  Duration get remaining {
    final startedAt = _startedAt;
    if (_paused || startedAt == null) return _budget;
    final left = _budget - now().difference(startedAt);
    return left.isNegative ? Duration.zero : left;
  }

  void add(IronNotice notice) {
    if (_current?.id == notice.id ||
        _queue.any((q) => q.notice.id == notice.id)) {
      return;
    }
    final current = _current;
    if (current == null) {
      _present(notice, notice.duration);
    } else if (notice.priority > current.priority) {
      // Desplaza al visible; si no era solo informativo y le queda tiempo,
      // vuelve a la cola con ese tiempo.
      final left = remaining;
      _stop();
      if (!current.isTransient && left > const Duration(seconds: 1)) {
        _enqueue(_Queued(current, left), ahead: true);
      }
      _present(notice, notice.duration);
    } else {
      _enqueue(_Queued(notice, notice.duration));
    }
  }

  void remove(String id) {
    _queue.removeWhere((q) => q.notice.id == id);
    if (_current?.id != id) return;
    _stop();
    _current = null;
    _paused = false;
    if (_queue.isEmpty) {
      notifyListeners();
    } else {
      final next = _queue.removeAt(0);
      _present(next.notice, next.remaining);
    }
  }

  /// Mientras el puntero está encima, el aviso no se cierra solo.
  void pause() {
    if (_current == null || _paused) return;
    _budget = remaining;
    _stop();
    _paused = true;
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    if (_current != null) _start(_budget);
  }

  /// Pulsar una acción la ejecuta y cierra el aviso.
  void runAction(String id, int index) {
    final notice = _current;
    if (notice == null || notice.id != id) return;
    if (index < 0 || index >= notice.actions.length) return;
    remove(id);
    notice.actions[index].onPressed();
  }

  @visibleForTesting
  void reset() {
    _stop();
    _queue.clear();
    _current = null;
    _paused = false;
  }

  void _enqueue(_Queued item, {bool ahead = false}) {
    final priority = item.notice.priority;
    var index = _queue.indexWhere(
      (q) =>
          ahead ? q.notice.priority <= priority : q.notice.priority < priority,
    );
    if (index < 0) index = _queue.length;
    _queue.insert(index, item);
    if (_queue.length > maxQueued) _queue.removeLast();
  }

  void _present(IronNotice notice, Duration duration) {
    _current = notice;
    _paused = false;
    _start(duration);
    notifyListeners();
  }

  void _start(Duration duration) {
    _budget = duration;
    _startedAt = now();
    final id = _current!.id;
    _timer = Timer(duration, () => remove(id));
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    _startedAt = null;
  }
}

class _Queued {
  _Queued(this.notice, this.remaining);

  final IronNotice notice;
  final Duration remaining;
}
