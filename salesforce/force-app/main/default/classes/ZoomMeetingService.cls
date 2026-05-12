/**
 * Creates a Zoom meeting via the Zoom REST API (Server-to-Server OAuth)
 * and writes the join URL back to ServiceAppointment.MeetingJoinUrl__c.
 *
 * Flow:
 *  1. Read Account ID, Client ID, Client Secret from ZoomCredential__mdt
 *  2. Exchange for a short-lived access token (POST zoom.us/oauth/token)
 *  3. Create the meeting (POST api.zoom.us/v2/users/me/meetings)
 *  4. Write join_url back to the ServiceAppointment record
 */
public without sharing class ZoomMeetingService {

    // ── Public entry point (called from trigger) ─────────────────────────────

    @future(callout=true)
    public static void createMeetingForAppointment(Id appointmentId) {
        ServiceAppointment sa = [
            SELECT Id, Subject, SchedStartTime, SchedEndTime, Description
            FROM ServiceAppointment
            WHERE Id = :appointmentId
            LIMIT 1
        ];

        try {
            String joinUrl = createZoomMeeting(sa);
            sa.MeetingJoinUrl__c = joinUrl;
            update sa;
            System.debug('ZoomMeetingService: join URL saved — ' + joinUrl);
        } catch (Exception e) {
            System.debug('ZoomMeetingService error for ' + appointmentId + ': '
                + e.getTypeName() + ': ' + e.getMessage());
        }
    }

    // ── Internal helpers ─────────────────────────────────────────────────────

    private static String createZoomMeeting(ServiceAppointment sa) {
        ZoomCredential__mdt cred = getCredential();
        String accessToken = getZoomToken(cred);
        return callZoomApi(accessToken, sa);
    }

    private static ZoomCredential__mdt getCredential() {
        List<ZoomCredential__mdt> creds = [
            SELECT AccountId__c, ClientId__c, ClientSecret__c
            FROM ZoomCredential__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        if (creds.isEmpty()) {
            throw new CalloutException('ZoomCredential__mdt.Default record not found.');
        }
        ZoomCredential__mdt c = creds[0];
        if (String.isBlank(c.AccountId__c) || c.AccountId__c.startsWith('REPLACE')) {
            throw new CalloutException('ZoomCredential__mdt.Default is not configured yet.');
        }
        return c;
    }

    // ── Step 1: obtain an access token via Server-to-Server OAuth ────────────

    private static String getZoomToken(ZoomCredential__mdt cred) {
        // Basic auth = Base64(clientId:clientSecret)
        String credentials = cred.ClientId__c + ':' + cred.ClientSecret__c;
        String basicAuth   = 'Basic ' + EncodingUtil.base64Encode(Blob.valueOf(credentials));

        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            'https://zoom.us/oauth/token'
            + '?grant_type=account_credentials'
            + '&account_id=' + EncodingUtil.urlEncode(cred.AccountId__c, 'UTF-8')
        );
        req.setMethod('POST');
        req.setHeader('Authorization', basicAuth);
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200) {
            throw new CalloutException('Zoom token error ' + res.getStatusCode() + ': ' + res.getBody());
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        return (String) body.get('access_token');
    }

    // ── Step 2: create the meeting and return the join URL ───────────────────

    private static String callZoomApi(String accessToken, ServiceAppointment sa) {
        String topic    = String.isNotBlank(sa.Subject) ? sa.Subject : 'Home Services Consultation';
        String startIso = sa.SchedStartTime != null
            ? sa.SchedStartTime.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'')
            : DateTime.now().addMinutes(5).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');

        // Duration in minutes — fall back to 60 if end time missing
        Integer durationMins = 60;
        if (sa.SchedStartTime != null && sa.SchedEndTime != null) {
            Long diffMs = sa.SchedEndTime.getTime() - sa.SchedStartTime.getTime();
            durationMins = (Integer)(diffMs / 60000);
            if (durationMins < 1) durationMins = 60;
        }

        Map<String, Object> payload = new Map<String, Object>{
            'topic'        => topic,
            'type'         => 2,              // scheduled meeting
            'start_time'   => startIso,
            'duration'     => durationMins,
            'timezone'     => 'America/New_York',
            'settings'     => new Map<String, Object>{
                'join_before_host'          => true,
                'waiting_room'              => false,
                'mute_upon_entry'           => false,
                'auto_recording'            => 'none'
            }
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://api.zoom.us/v2/users/me/meetings');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(payload));
        req.setTimeout(30000);

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
            throw new CalloutException('Zoom API error ' + res.getStatusCode() + ': ' + res.getBody());
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        String joinUrl = (String) body.get('join_url');
        if (String.isBlank(joinUrl)) {
            throw new CalloutException('Zoom API returned no join_url. Response: ' + res.getBody());
        }
        return joinUrl;
    }
}
