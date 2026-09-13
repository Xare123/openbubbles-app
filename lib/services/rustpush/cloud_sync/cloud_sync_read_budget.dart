/// Per-zone read work within one pass. Checkpoints remain authoritative.
final class CloudSyncReadBudget {
  const CloudSyncReadBudget({
    this.pagesPerPass = 4,
    this.retainedReplayEntries = 150,
  });

  static const standard = CloudSyncReadBudget();
  static const regular = CloudSyncReadBudget(
    pagesPerPass: 1,
    retainedReplayEntries: 32,
  );

  final int pagesPerPass;
  final int retainedReplayEntries;

  int get freshEntriesPerPass => pagesPerPass * 50;

  void validate() {
    if (pagesPerPass < 1 || pagesPerPass > 4) {
      throw ArgumentError.value(pagesPerPass, 'pagesPerPass', 'Must be 1..4');
    }
    if (retainedReplayEntries < 0 || retainedReplayEntries > 150) {
      throw ArgumentError.value(
        retainedReplayEntries,
        'retainedReplayEntries',
        'Must be 0..150',
      );
    }
  }
}
