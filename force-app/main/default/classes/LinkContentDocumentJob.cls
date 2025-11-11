public class LinkContentDocumentJob implements Queueable {
    private Id parentId;
    private Id contentVersionId;

    public LinkContentDocumentJob(Id parentId, Id contentVersionId) {
        this.parentId = parentId;
        this.contentVersionId = contentVersionId;
    }

    public void execute(QueueableContext context) {
        ContentVersion cv = [
            SELECT ContentDocumentId 
            FROM ContentVersion 
            WHERE Id = :contentVersionId
        ];

        ContentDocumentLink link = new ContentDocumentLink(
            ContentDocumentId = cv.ContentDocumentId,
            LinkedEntityId = parentId,
            ShareType = 'V'
        );
        insert link;
    }
}