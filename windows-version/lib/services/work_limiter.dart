import 'dart:async';
import 'dart:collection';

/// A bounded FIFO queue keeps a download burst from saturating the device.
class WorkLimiter {
  WorkLimiter(this.limit) : assert(limit > 0);
  final int limit;
  int _active = 0;
  final Queue<Completer<void>> _waiting = Queue();

  Future<T> run<T>(Future<T> Function() work) async {
    if (_active >= limit) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    try {
      return await work();
    } finally {
      if (_waiting.isNotEmpty) {
        _waiting.removeFirst().complete();
      } else {
        _active--;
      }
    }
  }
}
