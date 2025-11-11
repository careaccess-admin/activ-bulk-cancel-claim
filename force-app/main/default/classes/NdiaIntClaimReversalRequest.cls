public with sharing class NdiaIntClaimReversalRequest {
    static final String NAMED_CREDENTIAL = 'DefaultNDIACredential';
    
    @InvocableMethod(label='Process Claim Reversal Request')
public static void processRequests(List<Claim_Reversal_Request__c> records) {
    if (records == null || records.isEmpty()) return;

    for (Claim_Reversal_Request__c req : records) {
        try {
            // 1. Find attached CSV
            List<ContentDocumentLink> links = [
                SELECT ContentDocumentId 
                FROM ContentDocumentLink 
                WHERE LinkedEntityId = :req.Id
                LIMIT 1
            ];

            if (links.isEmpty()) {
                System.debug('No attached CSV found for record ' + req.Id);
                continue;
            }

            Id contentDocId = links[0].ContentDocumentId;
            ContentVersion cv = [
                SELECT VersionData 
                FROM ContentVersion 
                WHERE ContentDocumentId = :contentDocId 
                ORDER BY CreatedDate DESC 
                LIMIT 1
            ];

            // 2. Get CSV text
            String csvBody = cv.VersionData.toString();
            List<List<String>> rows = parseCsv(csvBody);
            if (rows.isEmpty()) continue;

            List<String> headers = rows[0];

            // Add result columns
            headers.addAll(new List<String>{'Success_Fail', 'Error_Message'});

            // Find required column indexes
            Integer idxNdisNumber = headers.indexOf('Client: NDIS Number');
            Integer idxClaimNumber = headers.indexOf('Original SDR: Current NDIS Extract Item: Payment Request Number');

            if (idxClaimNumber == -1 || idxNdisNumber == -1) {
                throw new AuraHandledException('Missing required columns in CSV.');
            }

            // Lists to hold output rows
            List<List<String>> allResults = new List<List<String>>();
            List<List<String>> successResults = new List<List<String>>();
            List<List<String>> errorResults = new List<List<String>>();

            // Add headers to all result lists
            allResults.add(headers);
            successResults.add(headers);
            errorResults.add(headers);

            // 3. Process each CSV row
            for (Integer i = 1; i < rows.size(); i++) {
                List<String> row = rows[i];
                String claimNumber = row.size() > idxClaimNumber ? row[idxClaimNumber] : null;
                String ndisNumber = row.size() > idxNdisNumber ? row[idxNdisNumber] : null;
                String resultType;
                String message;

                if (String.isBlank(claimNumber) || String.isBlank(ndisNumber)) {
                    resultType = 'Fail';
                    message = 'Missing Claim or NDIS Number';
                } else {
                    try {
                        HttpResponse response = cancelClaim(claimNumber, ndisNumber);
                        if (response != null && response.getStatusCode() == 200) {
                            resultType = 'Success';
                            message = response.getBody();
                        } else {
                            resultType = 'Fail';
                            message = response != null ? response.getBody() : 'No response';
                        }
                    } catch (Exception ex) {
                        resultType = 'Fail';
                        message = ex.getMessage();
                    }
                }

                // Clone the row to avoid mutating original list
                List<String> resultRow = new List<String>(row);
                resultRow.add(resultType);
                resultRow.add(message);

                allResults.add(resultRow);
                if (resultType == 'Success') {
                    successResults.add(resultRow);
                } else {
                    errorResults.add(resultRow);
                }
            }

            // 4. Generate file names with timestamp
            Datetime nowDt = Datetime.now();
            String timestamp = nowDt.format('yyyyMMdd_HHmmss');
            String baseName = 'NDIS_' + timestamp + '_Result';

            // 5. Build CSVs and attach all three
            attachCsv(req.Id, baseName + '.csv', buildCsv(allResults));
            attachCsv(req.Id, baseName + '_Success.csv', buildCsv(successResults));
            attachCsv(req.Id, baseName + '_Fail.csv', buildCsv(errorResults));

        } catch (Exception e) {
            System.debug('Error processing record ' + req.Id + ': ' + e.getMessage());
        }
    }
}
    
    // === Helper methods ===
    
    private static String buildCsv(List<List<String>> rows) {
        List<String> lines = new List<String>();
        for (List<String> row : rows) {
            List<String> escaped = new List<String>();
            for (String cell : row) {
                if (cell == null) cell = '';
                if (cell.contains('"') || cell.contains(',') || cell.contains('\n')) {
                    cell = '"' + cell.replace('"', '""') + '"';
                }
                escaped.add(cell);
            }
            lines.add(String.join(escaped, ','));
        }
        return String.join(lines, '\n');
    }
    
    private static void attachCsv(Id parentId, String title, String csvBody) {
        ContentVersion contentVersion = new ContentVersion();
        contentVersion.Title = title;
        contentVersion.PathOnClient = contentVersion.Title + '.csv';
        contentVersion.VersionData = Blob.valueOf(csvBody);
        contentVersion.ContentLocation = 'S';
        
        insert contentVersion;
        
        // Run async so ContentDocumentId is ready
		System.enqueueJob(new LinkContentDocumentJob(parentId, contentVersion.Id));
    }
    
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
    
    public static HttpResponse cancelClaim(String claimNumber, String ndisNumber) {
        System.debug('claimNumber: ' + claimNumber);
        System.debug('ndisNumber: ' + ndisNumber);
        String endpointUrl = getUrl(claimNumber);
        
        System.debug('endpointUrl: ' + endpointUrl);
        
        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpointUrl);
        request.setMethod('PATCH');
        request.setTimeout(120000);
        request.setHeader('participant', ndisNumber);
        
        System.debug('request: ' + request);
        
        Http http = new Http();
        HTTPResponse response = http.send(request);
        
        System.debug('response: ' + response);

        return response;
    }
    
    public static String getUrl(String claimNumber){
        return 'callout:' + NAMED_CREDENTIAL + '/ndia-middleware/v1/4.0/payments/' + claimNumber;
    }
}