/**
 * Calls the Microsoft Graph API to create a Teams online meeting
 * and returns the join URL. Uses Azure AD client-credentials flow
 * (app-only token) so no user interaction is ever required.
 *
 * Credentials are stored in the TeamsCredential__mdt custom metadata type.
 */
public without sharing class TeamsMeetingService {

    // ── Public entry point ───────────────────────────────────────────────────

    /**
     * Creates a Teams meeting for the given ServiceAppointment and writes
     * the join URL back to TeamsJoinUrl__c.
     * Called asynchronously from the trigger so it never blocks the booking.
     */
    @future(callout=true)
    public static void createMeetingForAppointment(Id appointmentId) {
        ServiceAppointment sa = [
            SELECT Id, Subject, SchedStartTime, SchedEndTime, Description
            FROM ServiceAppointment
            WHERE Id = :appointmentId
            LIMIT 1
        ];

        try {
            String joinUrl = createTeamsMeeting(sa);
            sa.TeamsJoinUrl__c = joinUrl;
            update sa;
        } catch (Exception e) {
            System.debug('TeamsMeetingService error for ' + appointmentId + ': ' + e.getMessage());
        }
    }

    // ── Internal helpers ─────────────────────────────────────────────────────

    private static String createTeamsMeeting(ServiceAppointment sa) {
        TeamsCredential__mdt cred = getCredential();

        String accessToken = getAzureToken(cred);
        String joinUrl     = callGraphApi(accessToken, cred.OrganizerUpn__c, sa);
        return joinUrl;
    }

    private static TeamsCredential__mdt getCredential() {
        List<TeamsCredential__mdt> creds = [
            SELECT TenantId__c, ClientId__c, ClientSecret__c, OrganizerUpn__c
            FROM TeamsCredential__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        if (creds.isEmpty()) {
            throw new CalloutException('TeamsCredential__mdt.Default not found. Deploy and populate the custom metadata record.');
        }
        TeamsCredential__mdt c = creds[0];
        if (String.isBlank(c.TenantId__c) || c.TenantId__c.startsWith('REPLACE')) {
            throw new CalloutException('TeamsCredential__mdt.Default is not configured. Populate TenantId, ClientId, ClientSecret, and OrganizerUpn.');
        }
        return c;
    }

    // ── Step 1: get an Azure AD app-only access token ────────────────────────

    private static String getAzureToken(TeamsCredential__mdt cred) {
        String tokenUrl = 'https://login.microsoftonline.com/' + cred.TenantId__c + '/oauth2/v2.0/token';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(tokenUrl);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setBody(
            'grant_type=client_credentials' +
            '&client_id='     + EncodingUtil.urlEncode(cred.ClientId__c,     'UTF-8') +
            '&client_secret=' + EncodingUtil.urlEncode(cred.ClientSecret__c, 'UTF-8') +
            '&scope='         + EncodingUtil.urlEncode('https://graph.microsoft.com/.default', 'UTF-8')
        );
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new CalloutException('Azure token error ' + res.getStatusCode() + ': ' + res.getBody());
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        return (String) body.get('access_token');
    }

    // ── Step 2: call Graph API to create the online meeting ──────────────────

    private static String callGraphApi(String accessToken, String organizerUpn, ServiceAppointment sa) {
        String subject = String.isNotBlank(sa.Subject) ? sa.Subject : 'Home Services Consultation';

        // Build ISO-8601 strings (Graph API requires UTC, no trailing Z — use format pattern)
        String startIso = formatIso(sa.SchedStartTime);
        String endIso   = formatIso(sa.SchedEndTime);

        Map<String, Object> payload = new Map<String, Object>{
            'subject'   => subject,
            'startDateTime' => startIso,
            'endDateTime'   => endIso
        };

        String endpoint = 'https://graph.microsoft.com/v1.0/users/'
            + EncodingUtil.urlEncode(organizerUpn, 'UTF-8')
            + '/onlineMeetings';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(payload));
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            throw new CalloutException('Graph API error ' + res.getStatusCode() + ': ' + res.getBody());
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String joinUrl = (String) body.get('joinWebUrl');
        if (String.isBlank(joinUrl)) {
            throw new CalloutException('Graph API returned no joinWebUrl. Response: ' + res.getBody());
        }
        return joinUrl;
    }

    // ── Utility ──────────────────────────────────────────────────────────────

    private static String formatIso(DateTime dt) {
        if (dt == null) return null;
        // Graph API expects "2026-05-13T14:00:00" (no trailing Z, UTC assumed)
        return dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss');
    }
}
