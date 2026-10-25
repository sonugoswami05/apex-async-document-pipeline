/**
 * Document types come from the Checklist_Item__c.Required_Document_Type__c picklist, so adding a
 * type is an admin change: the classifier is offered the new value on its next call.
 */
public inherited sharing class DocumentTypes {
    private static List<String> cachedValues;

    /** Active picklist values, in picklist order. Cached for the transaction. */
    public static List<String> values() {
        if (cachedValues == null) {
            cachedValues = new List<String>();
            for (Schema.PicklistEntry entry : Checklist_Item__c.Required_Document_Type__c.getDescribe().getPicklistValues()) {
                if (entry.isActive()) {
                    cachedValues.add(entry.getValue());
                }
            }
        }
        return cachedValues;
    }

    /**
     * Maps a free-text type onto a picklist value, ignoring case, underscores and outer spaces
     * ("bank_statement" becomes "Bank Statement"). Unknown types come back trimmed rather than
     * dropped, so a reviewer still sees what the service said.
     */
    public static String normalize(String rawType) {
        if (String.isBlank(rawType)) {
            return null;
        }
        String wanted = rawType.replace('_', ' ').normalizeSpace();
        for (String value : values()) {
            if (value.equalsIgnoreCase(wanted)) {
                return value;
            }
        }
        return rawType.trim().left(80);
    }
}
