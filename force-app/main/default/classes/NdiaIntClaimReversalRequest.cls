public with sharing class NdiaIntClaimReversalRequest {
    private static final Integer BATCH_SIZE = 10;
    private static final String NAMED_CREDENTIAL = 'ndiaint__DefaultNDIACredential';

    @InvocableMethod(label='Process Claim Reversal Request')
    public static void processRequests(List<Claim_Reversal_Request__c> requests) {
        if (requests == null || requests.isEmpty()) return;

        // We only ever expect one record
        Claim_Reversal_Request__c req = requests[0];

        try {
            // 1. Find the CSV attachment
            List<ContentDocumentLink> links = [
                SELECT ContentDocumentId 
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :req.Id
            ];

            if (links.isEmpty()) {
                System.debug('No attachments found for record ' + req.Id);
                return;
            }

            // 2. Extract the Ids
            Set<Id> docIds = new Set<Id>();
            for (ContentDocumentLink link : links) {
                docIds.add(link.ContentDocumentId);
            }

            // 3. Find ContentVersion whose Title starts with "Reversals"
            List<ContentVersion> cvs = [
                SELECT VersionData, Title
                FROM ContentVersion
                WHERE ContentDocumentId IN :docIds
                AND Title LIKE 'Reversals%'
                ORDER BY CreatedDate DESC
                LIMIT 1
            ];

            if (cvs.isEmpty()) {
                System.debug('No attached CSV with title starting with "Reversals" found for record ' + req.Id);
                return;
            }

            ContentVersion cv = cvs[0];


            String csvBody = cv.VersionData.toString();
            List<List<String>> rows = parseCsv(csvBody);
            if (rows.isEmpty()) return;

            String deviceName = NAMED_CREDENTIAL;
            
            if(String.isBlank(req.Entity__c) == false) {
                deviceName = req.Entity__c;
            }

            // 2. Start the first queueable batch
            System.enqueueJob(new ClaimReversalQueueable(
                req.Id,
                req.Name,
                deviceName,
                rows,
                0,
                BATCH_SIZE,
                new List<List<String>>(), // all
                new List<List<String>>(), // success
                new List<List<String>>()  // fail
            ));

        } catch (Exception e) {
            System.debug('Error starting processing for record ' + req.Id + ': ' + e.getMessage());
        }
    }

    // === Helper: simple CSV parser ===
    public static List<List<String>> parseCsv(String csv) {
        List<List<String>> allRows = new List<List<String>>();
        List<String> currentRow = new List<String>();
        String currentValue = '';
        Boolean inQuotes = false;

        for (Integer i = 0; i < csv.length(); i++) {
            String ch = csv.substring(i, i+1);
            if (ch == '"') {
                if (inQuotes && i+1 < csv.length() && csv.substring(i+1, i+2) == '"') {
                    currentValue += '"';
                    i++;
                } else {
                    inQuotes = !inQuotes;
                }
            } else if (ch == ',' && !inQuotes) {
                currentRow.add(currentValue);
                currentValue = '';
            } else if ((ch == '\n' || ch == '\r') && !inQuotes) {
                if (currentValue != '' || currentRow.size() > 0) {
                    currentRow.add(currentValue);
                    allRows.add(currentRow);
                    currentRow = new List<String>();
                    currentValue = '';
                }
            } else {
                currentValue += ch;
            }
        }
        if (currentValue != '' || currentRow.size() > 0) {
            currentRow.add(currentValue);
            allRows.add(currentRow);
        }

        return allRows;
    }
}