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
                
				// Find the index of the two required columns
                Integer idxNdisNumber = headers.indexOf('Client: NDIS Number');
                Integer idxClaimNumber = headers.indexOf('Original SDR: Current NDIS Extract Item: Payment Request Number');
                
                if (idxClaimNumber == -1 || idxNdisNumber == -1) {
                    throw new AuraHandledException('Missing required columns in CSV.');
                }
                
                List<List<String>> results = new List<List<String>>();
                results.add(new List<String>{'LineNumber', 'Status', 'ResponseMessage'});
                
                // 3. Process each CSV row
                for (Integer i = 1; i < rows.size(); i++) {
                    List<String> row = rows[i];
                    String claimNumber = row.size() > idxClaimNumber ? row[idxClaimNumber] : null;
                    String ndisNumber = row.size() > idxNdisNumber ? row[idxNdisNumber] : null;
                    
                    if (String.isBlank(claimNumber) || String.isBlank(ndisNumber)) {
                        results.add(new List<String>{
                            String.valueOf(i), claimNumber, ndisNumber, 'Skipped', 'Missing Claim or NDIS Number'
                        });
                        continue;
                    }
                    
                    try {
                        HttpResponse response = cancelClaim(claimNumber, ndisNumber);
                        
                        System.debug('response: ' + response);
                        
                        results.add(new List<String>{
                            String.valueOf(i),
                            claimNumber,
                            ndisNumber,
                            'Success',
                            response != null ? response.getBody() : 'No response'
                        });
                    } catch (Exception ex) {
                        results.add(new List<String>{
                            String.valueOf(i),
                            claimNumber,
                            ndisNumber,
                            'Error',
                            ex.getMessage()
                        });
                    }
                }
                
                // 4. Build result CSV and attach
                String resultCsv = buildCsv(results);
                attachCsv(req.Id, resultCsv);
                
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
    
    private static void attachCsv(Id parentId, String csvBody) {
        ContentVersion contentVersion = new ContentVersion();
        contentVersion.Title = 'Results_' + Datetime.now().format('yyyyMMdd_HHmmss');
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
    
    /*
    // === Lightweight inline CSV parser ===
    public class CsvParser {
        public static List<List<String>> parse(String csv) {
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
    
    // === Example API Service Stub (replace with your own implementation) ===
    private class ExternalService {
        public static String callApi(List<String> row) {
            // This should use your existing Named Credential and call logic.
            // Example placeholder:
            return 'Processed successfully for ' + String.join(row, ',');
        }
    }
	*/
}