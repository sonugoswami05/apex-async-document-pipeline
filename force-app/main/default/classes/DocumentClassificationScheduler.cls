/**
 * Starts DocumentClassificationBatch on a schedule. Example, every 15 minutes:
 *
 *   for (Integer minute : new List<Integer>{ 0, 15, 30, 45 }) {
 *       System.schedule('Document classification :' + minute,
 *           '0 ' + minute + ' * * * ?', new DocumentClassificationScheduler());
 *   }
 *
 * DocumentClassificationBatch.run() skips the start if a previous run is still going.
 */
public with sharing class DocumentClassificationScheduler implements Schedulable {
    public void execute(SchedulableContext context) {
        DocumentClassificationBatch.run();
    }
}
