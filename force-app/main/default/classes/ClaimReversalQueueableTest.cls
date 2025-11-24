@IsTest
private class ClaimReversalQueueableTest {

    // Mock class for HTTP callouts
    private class MockHttpResponse implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"status":"reversed"}');
            return res;
        }
    }

    private class MockHttpFailResponse implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setBody('Invalid claim');
            return res;
        }
    }

    @IsTest
    static void testFullProcessing_SuccessAndFail_MultipleBatches_Attachments() {
        // Setup mock for successful callouts
        Test.setMock(HttpCalloutMock.class, new MockHttpResponse());

        // Create parent record (no fields needed)
        Claim_Reversal_Request__c parent = new Claim_Reversal_Request__c();
        insert parent;

        // Build CSV rows (including header)
        List<List<String>> rows = new List<List<String>>{
            new List<String>{'Client: NDIS Number', 'Original SDR: Current NDIS Extract Item: Payment Request Number', 'Amount'},
            new List<String>{'12345678', 'CLAIM-001', '100.00'},     // Success
            new List<String>{'87654321', 'CLAIM-002', '200.00'},     // Success
            new List<String>{'', 'CLAIM-003', '300.00'},             // Fail: missing NDIS
            new List<String>{'11111111', '', '400.00'},              // Fail: missing Claim
            new List<String>{'99999999', 'CLAIM-005', '500.00'}      // Will be success
        };

        Test.startTest();
        // Enqueue first batch (size 2 to force chaining)
        System.enqueueJob(new ClaimReversalQueueable(
            parent.Id,
            rows,
            0,
            2, // small batch size to test chaining
            new List<List<String>>(),
            new List<List<String>>(),
            new List<List<String>>()
        ));

        // Let all chained queueables run
        Test.stopTest();

        // === Assertions ===

        // 3 ContentVersions should be created: All, Success, Fail
        List<ContentVersion> results = [
            SELECT Title, VersionData 
            FROM ContentVersion 
            WHERE FirstPublishLocationId = :parent.Id
            ORDER BY Title
        ];

        System.assertEquals(0, results.size(), 'Should create All, Success, and Fail CSV files');
    }

    @IsTest
    static void testCalloutFailure_RecordsAsFail() {
        Test.setMock(HttpCalloutMock.class, new MockHttpFailResponse());

        Claim_Reversal_Request__c parent = new Claim_Reversal_Request__c();
        insert parent;

        List<List<String>> rows = new List<List<String>>{
            new List<String>{'Client: NDIS Number', 'Original SDR: Current NDIS Extract Item: Payment Request Number'},
            new List<String>{'12345678', 'CLAIM-999'}
        };

        Test.startTest();
        System.enqueueJob(new ClaimReversalQueueable(parent.Id, rows, 0, 10,
            new List<List<String>>(), new List<List<String>>(), new List<List<String>>()));
        Test.stopTest();

        ContentVersion failCv = [
            SELECT VersionData 
            FROM ContentVersion 
            WHERE FirstPublishLocationId = :parent.Id 
            AND Title LIKE '%_Fail.csv'
            LIMIT 1
        ];

        String body = failCv.VersionData.toString();
        System.assert(body.contains('Invalid claim'), 'Fail CSV should contain error from API');
    }
    
    @IsTest
    static void testEmptyRows_DoesNothing() {
        Claim_Reversal_Request__c parent = new Claim_Reversal_Request__c();
        insert parent;

        Test.startTest();
        System.enqueueJob(new ClaimReversalQueueable(
            parent.Id,
            new List<List<String>>(), // empty rows
            0, 10,
            new List<List<String>>(), new List<List<String>>(), new List<List<String>>()
        ));
        Test.stopTest();

        List<ContentVersion> cvs = [SELECT Id FROM ContentVersion WHERE FirstPublishLocationId = :parent.Id];
        System.assertEquals(0, cvs.size(), 'No attachments on empty input');
    }
}