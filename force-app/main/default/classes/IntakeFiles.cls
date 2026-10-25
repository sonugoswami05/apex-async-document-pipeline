/**
 * Loads the files behind Document_Intake__c records, in two steps so an oversized file body is
 * never pulled into the heap: metadata for every file first, then bodies only for files under
 * the size cap.
 */
public with sharing class IntakeFiles {
    /** Latest version metadata (no body) keyed by ContentDocumentId. */
    public static Map<Id, ContentVersion> latestVersions(List<Document_Intake__c> intakes) {
        Set<Id> documentIds = new Set<Id>();
        for (Document_Intake__c intake : intakes) {
            Id documentId = toId(intake.Content_Document_Id__c);
            if (documentId != null) {
                documentIds.add(documentId);
            }
        }
        Map<Id, ContentVersion> byDocument = new Map<Id, ContentVersion>();
        if (documentIds.isEmpty()) {
            return byDocument;
        }
        for (ContentVersion version : [
            SELECT Id, ContentDocumentId, Title, FileExtension, ContentSize
            FROM ContentVersion
            WHERE ContentDocumentId IN :documentIds AND IsLatest = TRUE
            WITH USER_MODE
        ]) {
            byDocument.put(version.ContentDocumentId, version);
        }
        return byDocument;
    }

    /** VersionData keyed by ContentVersion Id, for versions at or under maxBytes only. */
    public static Map<Id, ContentVersion> bodiesUnder(List<ContentVersion> versions, Integer maxBytes) {
        Set<Id> eligible = new Set<Id>();
        for (ContentVersion version : versions) {
            if (version.ContentSize <= maxBytes) {
                eligible.add(version.Id);
            }
        }
        if (eligible.isEmpty()) {
            return new Map<Id, ContentVersion>();
        }
        return new Map<Id, ContentVersion>([
            SELECT Id, VersionData FROM ContentVersion WHERE Id IN :eligible WITH USER_MODE
        ]);
    }

    /** Text field to Id. Returns null for blank or malformed values instead of throwing. */
    public static Id toId(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Id.valueOf(value.trim());
        } catch (StringException e) {
            return null;
        }
    }
}
