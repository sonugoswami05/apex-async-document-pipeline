import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getDocumentsForReview from '@salesforce/apex/IntakeReviewController.getDocumentsForReview';
import getDocumentTypeOptions from '@salesforce/apex/IntakeReviewController.getDocumentTypeOptions';
import saveDecisions from '@salesforce/apex/IntakeReviewController.saveDecisions';

const COLUMNS = [
    {
        label: 'Intake',
        fieldName: 'recordUrl',
        type: 'url',
        typeAttributes: { label: { fieldName: 'name' }, target: '_self' },
        initialWidth: 130
    },
    { label: 'File', fieldName: 'fileName', wrapText: true },
    { label: 'Application', fieldName: 'applicationName' },
    { label: 'Suggested type', fieldName: 'suggestedType' },
    {
        label: 'Confidence',
        fieldName: 'confidence',
        type: 'percent',
        typeAttributes: { minimumFractionDigits: 0, maximumFractionDigits: 1 },
        cellAttributes: { alignment: 'left' },
        initialWidth: 120
    },
    { label: 'Why it needs review', fieldName: 'reviewReason', wrapText: true }
];

/** Turns an Apex, wire or JS error into one readable line. */
function reduceError(error) {
    if (!error) {
        return 'Unknown error';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((entry) => entry.message).join(', ');
    }
    if (error.body && typeof error.body.message === 'string') {
        return error.body.message;
    }
    return typeof error.message === 'string' ? error.message : 'Unknown error';
}

export default class IntakeReview extends LightningElement {
    /** Set automatically on a record page. On an app page it stays empty and all documents show. */
    @api recordId;

    columns = COLUMNS;
    rows = [];
    typeOptions = [];
    selectedIds = [];
    overrideType;
    error;
    isLoading = true;
    isSaving = false;
    wiredRowsResult;

    /**
     * The wire service does not run while a reactive parameter is undefined, which recordId is on
     * an app page. Passing null instead means "no filter".
     */
    get applicationId() {
        return this.recordId || null;
    }

    @wire(getDocumentsForReview, { applicationId: '$applicationId' })
    wiredRows(result) {
        this.wiredRowsResult = result;
        const { data, error } = result;
        if (data) {
            this.rows = data.map((row) => ({ ...row, recordUrl: `/${row.intakeId}` }));
            this.error = undefined;
            this.isLoading = false;
        } else if (error) {
            this.rows = [];
            this.error = reduceError(error);
            this.isLoading = false;
        }
    }

    @wire(getDocumentTypeOptions)
    wiredTypes({ data, error }) {
        if (data) {
            this.typeOptions = data.map((option) => ({ label: option.label, value: option.value }));
        } else if (error) {
            this.error = reduceError(error);
        }
    }

    get cardTitle() {
        return `Documents to review (${this.rows.length})`;
    }

    get hasRows() {
        return this.rows.length > 0;
    }

    get showEmptyState() {
        return !this.isLoading && !this.error && !this.hasRows;
    }

    get selectionLabel() {
        const count = this.selectedIds.length;
        return count === 1 ? '1 document selected' : `${count} documents selected`;
    }

    get disableAccept() {
        return this.isSaving || this.selectedIds.length === 0;
    }

    get disableOverride() {
        return this.disableAccept || !this.overrideType;
    }

    handleRowSelection(event) {
        this.selectedIds = event.detail.selectedRows.map((row) => row.intakeId);
    }

    handleTypeChange(event) {
        this.overrideType = event.detail.value;
    }

    handleRefresh() {
        return refreshApex(this.wiredRowsResult);
    }

    handleAccept() {
        const selected = this.rows.filter((row) => this.selectedIds.includes(row.intakeId));
        const withoutSuggestion = selected.filter((row) => !row.suggestedType);
        if (withoutSuggestion.length > 0) {
            this.toast(
                'Pick a type first',
                `${withoutSuggestion.length} selected document(s) have no suggestion. Use Override type for those.`,
                'warning'
            );
            return Promise.resolve();
        }
        return this.save(selected.map((row) => ({ intakeId: row.intakeId, documentType: row.suggestedType })));
    }

    handleOverride() {
        return this.save(this.selectedIds.map((intakeId) => ({ intakeId, documentType: this.overrideType })));
    }

    async save(decisions) {
        this.isSaving = true;
        try {
            const results = await saveDecisions({ decisions });
            const failures = results.filter((result) => !result.success);
            const saved = results.length - failures.length;

            if (saved > 0) {
                this.toast('Saved', `${saved} document(s) allocated.`, 'success');
            }
            if (failures.length > 0) {
                const firstReason = failures[0].message;
                this.toast(
                    `${failures.length} document(s) not saved`,
                    failures.length === 1 ? firstReason : `${firstReason} (and ${failures.length - 1} more)`,
                    'error'
                );
            }

            this.selectedIds = [];
            this.overrideType = undefined;
            await refreshApex(this.wiredRowsResult);
        } catch (error) {
            this.toast('Could not save', reduceError(error), 'error');
        } finally {
            this.isSaving = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
