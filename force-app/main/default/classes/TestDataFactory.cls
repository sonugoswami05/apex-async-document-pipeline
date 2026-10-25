/**
 * Test data builders. Tests run as a Standard User with the Document_Pipeline_User permission set,
 * so user-mode queries and DML are exercised the way a real pipeline user would hit them.
 */
@IsTest
public class TestDataFactory {
    public static final String PIPELINE_USER_LAST_NAME = 'PipelineTestUser';
    public static final String PERMISSION_SET_NAME = 'Document_Pipeline_User';

    /** Inserts a Standard User with the pipeline permission set. Call outside System.runAs. */
    public static User createPipelineUser() {
        Profile standardProfile = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = EncodingUtil.convertToHex(Crypto.generateAesKey(128)).left(12);
        User pipelineUser = new User(
            Alias = 'pipeusr',
            Email = 'pipeline.user@example.com',
            EmailEncodingKey = 'UTF-8',
            FirstName = 'Pipeline',
            LastName = PIPELINE_USER_LAST_NAME,
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'America/New_York',
            Username = 'pipeline.' + unique + '@example.com'
        );
        insert pipelineUser;

        PermissionSet permissionSet = [SELECT Id FROM PermissionSet WHERE Name = :PERMISSION_SET_NAME LIMIT 1];
        insert new PermissionSetAssignment(AssigneeId = pipelineUser.Id, PermissionSetId = permissionSet.Id);
        return pipelineUser;
    }

    /** The user created in @TestSetup. */
    public static User pipelineUser() {
        return [SELECT Id FROM User WHERE LastName = :PIPELINE_USER_LAST_NAME ORDER BY CreatedDate DESC LIMIT 1];
    }

    public static Application__c createApplication(String name) {
        Application__c application = new Application__c(Name = name, Status__c = 'Open');
        insert application;
        return application;
    }

    /** One Open checklist item per type. */
    public static List<Checklist_Item__c> createChecklist(Id applicationId, List<String> documentTypes) {
        List<Checklist_Item__c> items = new List<Checklist_Item__c>();
        for (String documentType : documentTypes) {
            items.add(new Checklist_Item__c(
                Name = documentType,
                Application__c = applicationId,
                Required_Document_Type__c = documentType,
                Status__c = IntakeStatus.ITEM_OPEN
            ));
        }
        insert items;
        return items;
    }

    /** Uploads a file of roughly sizeBytes and returns its ContentDocumentId. */
    public static Id createFile(String title, Integer sizeBytes) {
        ContentVersion version = new ContentVersion(
            Title = title,
            PathOnClient = title + '.pdf',
            VersionData = Blob.valueOf('x'.repeat(Math.max(1, sizeBytes)))
        );
        insert version;
        return [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :version.Id].ContentDocumentId;
    }

    public static List<Document_Intake__c> buildIntakes(Id applicationId, Id contentDocumentId, Integer count) {
        List<Document_Intake__c> intakes = new List<Document_Intake__c>();
        for (Integer i = 0; i < count; i++) {
            intakes.add(new Document_Intake__c(
                Application__c = applicationId,
                Content_Document_Id__c = contentDocumentId,
                File_Name__c = 'document-' + i + '.pdf'
            ));
        }
        return intakes;
    }

    public static List<Document_Intake__c> createIntakes(Id applicationId, Id contentDocumentId, Integer count) {
        List<Document_Intake__c> intakes = buildIntakes(applicationId, contentDocumentId, count);
        insert intakes;
        return intakes;
    }

    /** Classification values to stamp onto test intakes. */
    public static Document_Intake__c classified(String suggestedType, Decimal confidencePercent) {
        return new Document_Intake__c(Suggested_Type__c = suggestedType, Confidence__c = confidencePercent);
    }

    /** Intakes already classified and waiting for allocation. */
    public static List<Document_Intake__c> createClassifiedIntakes(
        Id applicationId, Integer count, Document_Intake__c classification
    ) {
        List<Document_Intake__c> intakes = buildIntakes(applicationId, null, count);
        for (Document_Intake__c intake : intakes) {
            intake.Status__c = IntakeStatus.CLASSIFYING;
            intake.Suggested_Type__c = classification.Suggested_Type__c;
            intake.Confidence__c = classification.Confidence__c;
            intake.Attempt_Count__c = 1;
        }
        insert intakes;
        return intakes;
    }

    /** Pins pipeline settings for the current test instead of relying on the deployed record. */
    public static void useSettings(Decimal confidenceThreshold, Integer maxAttempts, Integer baseBackoffMinutes) {
        PipelineSettings.current = new Pipeline_Setting__mdt(
            Confidence_Threshold__c = confidenceThreshold,
            Max_Attempts__c = maxAttempts,
            Base_Backoff_Minutes__c = baseBackoffMinutes
        );
    }

    public static List<Document_Intake__c> reload(Set<Id> intakeIds) {
        return [
            SELECT Id, Status__c, Suggested_Type__c, Confirmed_Type__c, Confidence__c, Checklist_Item__c,
                Attempt_Count__c, Next_Attempt_At__c, Last_Error__c, Review_Reason__c, Application__c
            FROM Document_Intake__c
            WHERE Id IN :intakeIds
            ORDER BY CreatedDate, Id
        ];
    }

    public static Set<Id> idsOf(List<SObject> records) {
        return new Map<Id, SObject>(records).keySet();
    }
}
