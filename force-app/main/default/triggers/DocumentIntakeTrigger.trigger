/**
 * One trigger per object; all logic lives in DocumentIntakeTriggerHandler.
 */
trigger DocumentIntakeTrigger on Document_Intake__c (before insert, before update, after update) {
    new DocumentIntakeTriggerHandler().run();
}
