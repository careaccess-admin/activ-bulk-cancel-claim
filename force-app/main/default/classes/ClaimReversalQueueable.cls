public with sharing class ClaimReversalQueueable implements Queueable, Database.AllowsCallouts {
    private Id parentId;
    private String parentName;
    private String deviceName;
    private List<List<String>> rows;
    private Integer startIndex;
    private Integer batchSize;
    private List<List<String>> allResults;
    private List<List<String>> successResults;
    private List<List<String>> failResults;

    public ClaimReversalQueueable(
        Id parentId,
        String parentName,
        String deviceName,
        List<List<String>> rows,
        Integer startIndex,
        Integer batchSize,
        List<List<String>> allResults,
        List<List<String>> successResults,
        List<List<String>> failResults
    ) {
        this.parentId = parentId;
        this.parentName = parentName;
        this.deviceName = deviceName;
        this.rows = rows;
        this.startIndex = startIndex;
        this.batchSize = batchSize;
        this.allResults = allResults;
        this.successResults = successResults;
        this.failResults = failResults;
    }

    public void execute(QueueableContext context) {
        try {
            if (rows.isEmpty()) return;

            List<String> headers = rows[0];

            // On first run, add headers + result columns
            if (allResults.isEmpty()) {
                headers.addAll(new List<String>{'Success_Fail', 'Error_Message'});
                allResults.add(headers);
                successResults.add(headers);
                failResults.add(headers);
            }

            Integer idxNdisNumber = headers.indexOf('Client: NDIS Number');
            Integer idxClaimNumber = headers.indexOf('Original SDR: Current NDIS Extract Item: Payment Request Number');

            if (idxClaimNumber == -1 || idxNdisNumber == -1) {
                throw new AuraHandledException('Missing required columns in CSV.');
            }

            Integer endIndex = Math.min(startIndex + batchSize, rows.size());

            System.debug('Processing rows ' + startIndex + ' to ' + (endIndex - 1));

            //Remove header line
            if(startIndex == 0) {
                startIndex += 1;
            }

            for (Integer i = startIndex; i < endIndex; i++) {
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
                        HttpResponse response = cancelClaim(claimNumber, ndisNumber, deviceName);
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

                List<String> resultRow = new List<String>(row);
                resultRow.add(resultType);
                resultRow.add(message);

                allResults.add(resultRow);
                if (resultType == 'Success') {
                    successResults.add(resultRow);
                } else {
                    failResults.add(resultRow);
                }
            }

            // If more rows remain, chain next queueable
            if (endIndex < rows.size()) {
                System.enqueueJob(new ClaimReversalQueueable(
                    parentId, parentName, deviceName, rows, endIndex, batchSize, allResults, successResults, failResults
                ));
            } else {
                // Finished all rows, attach results
                Datetime nowDt = Datetime.now();
                String timestamp = nowDt.format('yyyyMMdd_HHmmss');
                String baseName = 'NDIS_' + timestamp + '_Result';

                attachCsv(parentId, baseName + '.csv', buildCsv(allResults));
                attachCsv(parentId, baseName + '_Success.csv', buildCsv(successResults));
                attachCsv(parentId, baseName + '_Fail.csv', buildCsv(failResults));
                
                sendBellNotification(parentId, parentName);
            }

        } catch (Exception e) {
            System.debug('Error in queueable: ' + e.getMessage());
        }
    }

    // === Helper methods ===
     
    private static String getNotificationTypeId(){
        CustomNotificationType notificationType = [SELECT Id 
                                                   FROM CustomNotificationType 
                                                   WHERE DeveloperName = 'NDIA_Integration_Notification' 
                                                   LIMIT 1];
        
        return notificationType.Id;
    }
     
    private static void sendBellNotification(String targetId, String targetName) {
        Set<String> recipientIds = new Set<String>{UserInfo.getUserId()};
        String title = targetName + ' | Bulk Claim Reversal';
        String message = 'Your Claim Reversal Request finished processing. Click here to see the results!';
        String notificationTypeId = getNotificationTypeId();

        // Step 1: Stop if missing mandatory information
        if(notificationTypeId == null || recipientIds == null) {
            return;
		}
        
        // Step 2: Create a new custom notification
        Messaging.CustomNotification notification = new Messaging.CustomNotification();
        
        // Step 3: Set the notification details
        notification.setTitle(title);
        notification.setBody(message);
        notification.setSenderId(UserInfo.getUserId()); // Optional: Set the sender (current user)
        notification.setNotificationTypeId(notificationTypeId); // Link to your custom notification type
        notification.setTargetId(targetId); // The record ID to link the notification to (e.g., an Opportunity or Case ID)
        
        // Step 4: Send the notification to the specified recipients
        try {
            notification.send(recipientIds);
        } catch (Exception e) {
            System.debug('Error sending notification: ' + e.getMessage());
        }
    }

    private static HttpResponse cancelClaim(String claimNumber, String ndisNumber, String deviceName) {
        String endpointUrl = 'callout:' + deviceName + '/ndia-middleware/v1/4.0/payments/' + claimNumber;

        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpointUrl);
        request.setMethod('PATCH');
        request.setTimeout(120000);
        request.setHeader('participant', ndisNumber);

        Http http = new Http();
        return http.send(request);
    }

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
        ContentVersion cv = new ContentVersion(
            Title = title,
            PathOnClient = title,
            VersionData = Blob.valueOf(csvBody),
            ContentLocation = 'S',
            FirstPublishLocationId = parentId
        );
        insert cv;
    }
}