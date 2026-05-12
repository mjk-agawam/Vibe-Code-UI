public without sharing class CostcoSchedulerController {

    private static final String TERRITORY_ID  = '0HhHu000001TK26KAG';
    private static final String API_VERSION   = 'v63.0';
    private static final String BASE_URL      = 'https://mjk-260320.my.salesforce.com';

    // Per-transaction token cache (populated from SchedulerCredential__mdt)
    private static String cachedToken;

    // ── Company definitions ──────────────────────────────────────────────────
    private static final List<Map<String, String>> COMPANY_DATA = new List<Map<String, String>>{
        new Map<String, String>{
            'id' => 'roofing', 'name' => 'Summit Roofing Co.',
            'tagline' => 'Expert roof replacement & repair',
            'service' => 'Roofing', 'color' => '#D4501A', 'icon' => 'utility:home',
            'workTypeGroupId' => '0VSHu000001KAx7OAG', 'workTypeId' => '08qHu000001HT99IAG'
        },
        new Map<String, String>{
            'id' => 'hvac', 'name' => 'CoolBreeze HVAC',
            'tagline' => 'Heating, cooling & air quality solutions',
            'service' => 'HVAC', 'color' => '#1A6DD4', 'icon' => 'utility:connected_apps',
            'workTypeGroupId' => '0VSHu000001KAx8OAG', 'workTypeId' => '08qHu000001HT9AIAW'
        },
        new Map<String, String>{
            'id' => 'windows', 'name' => 'ClearView Home Solutions',
            'tagline' => 'Premium window & door replacement',
            'service' => 'Windows & Doors', 'color' => '#5A1AD4', 'icon' => 'utility:layout',
            'workTypeGroupId' => '0VSHu000001KAx9OAG', 'workTypeId' => '08qHu000001HT9BIAW'
        },
        new Map<String, String>{
            'id' => 'awnings', 'name' => 'ShadeCraft Awnings',
            'tagline' => 'Custom outdoor shade & awning design',
            'service' => 'Custom Awnings', 'color' => '#1AB85A', 'icon' => 'utility:umbrella',
            'workTypeGroupId' => '0VSHu000001KAxAOAW', 'workTypeId' => '08qHu000001HT9CIAW'
        },
        new Map<String, String>{
            'id' => 'solar', 'name' => 'SunRise Solar',
            'tagline' => 'Solar panel installation & energy savings',
            'service' => 'Solar Panels', 'color' => '#D4A81A', 'icon' => 'utility:dayview',
            'workTypeGroupId' => '0VSHu000001KAxBOAW', 'workTypeId' => '08qHu000001HT9DIAW'
        },
        new Map<String, String>{
            'id' => 'garage', 'name' => 'ProLift Garage Doors',
            'tagline' => 'Garage door installation & replacement',
            'service' => 'Garage Doors', 'color' => '#7A1AD4', 'icon' => 'utility:open_folder',
            'workTypeGroupId' => '0VSHu000001KAxCOAW', 'workTypeId' => '08qHu000001HT9EIAW'
        }
    };

    @AuraEnabled(cacheable=false)
    public static List<Map<String, String>> getCompanies() {
        List<Map<String, String>> result = new List<Map<String, String>>();
        for (Map<String, String> c : COMPANY_DATA) {
            result.add(new Map<String, String>{
                'id'      => c.get('id'),
                'name'    => c.get('name'),
                'tagline' => c.get('tagline'),
                'service' => c.get('service'),
                'color'   => c.get('color'),
                'icon'    => c.get('icon')
            });
        }
        return result;
    }

    // ── Get available slots ──────────────────────────────────────────────────
    @AuraEnabled
    public static String getAvailableSlots(String workTypeGroupId, String startDate, String endDate) {
        try {
            Map<String, Object> payload = new Map<String, Object>{
                'startTime'       => startDate,
                'endTime'         => endDate,
                'workTypeGroupId' => workTypeGroupId,
                'territoryIds'    => new List<String>{ TERRITORY_ID }
            };

            HttpResponse res = sfCallout(
                'POST',
                '/services/data/' + API_VERSION + '/connect/scheduling/available-territory-slots',
                JSON.serialize(payload)
            );

            if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
                throw new AuraHandledException('Slots API error ' + res.getStatusCode() + ': ' + res.getBody());
            }

            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Object rootObj = body.containsKey('result') ? body.get('result') : body;
            Map<String, Object> root = (Map<String, Object>) rootObj;

            List<Object> territorySlotsRaw = (List<Object>) root.get('territorySlots');
            List<Map<String, String>> timeSlots = new List<Map<String, String>>();
            Set<String> seen = new Set<String>();

            if (territorySlotsRaw != null && !territorySlotsRaw.isEmpty()) {
                Map<String, Object> firstTerritory = (Map<String, Object>) territorySlotsRaw[0];
                List<Object> rawSlots = (List<Object>) firstTerritory.get('slots');
                if (rawSlots != null) {
                    for (Object slotObj : rawSlots) {
                        Map<String, Object> slot = (Map<String, Object>) slotObj;
                        String startTime = (String) slot.get('startTime');
                        if (startTime != null && startTime.contains('T') && !seen.contains(startTime)) {
                            String timePart = startTime.substringAfter('T');
                            String minutes  = timePart.substring(3, 5);
                            if (minutes == '00') {
                                seen.add(startTime);
                                timeSlots.add(new Map<String, String>{
                                    'startTime' => startTime,
                                    'endTime'   => (String) slot.get('endTime')
                                });
                            }
                        }
                    }
                }
            }

            return JSON.serialize(new Map<String, Object>{ 'timeSlots' => timeSlots });
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            String msg = e.getMessage();
            throw new AuraHandledException(String.isBlank(msg) ? e.getTypeName() : msg);
        }
    }

    // ── Create booking ───────────────────────────────────────────────────────
    @AuraEnabled
    public static String createBooking(
        String workTypeGroupId, String workTypeId,
        String schedStartTime,  String schedEndTime,
        String firstName,       String lastName,
        String email,           String phone,
        String notes,           String companyName,
        String serviceName
    ) {
        try {
            String description = (String.isNotBlank(notes) ? 'Notes: ' + notes : '');

            Map<String, Object> serviceAppt = new Map<String, Object>{
                'workTypeId'         => workTypeId,
                'serviceTerritoryId' => TERRITORY_ID,
                'schedStartTime'     => schedStartTime,
                'schedEndTime'       => schedEndTime,
                'appointmentType'    => 'In Person',
                'extendedFields'     => String.isNotBlank(description)
                    ? new List<Map<String, String>>{ new Map<String, String>{'name'=>'Description','value'=>description} }
                    : new List<Map<String, String>>()
            };

            Map<String, Object> lead = new Map<String, Object>{
                'firstName'     => firstName,
                'lastName'      => lastName,
                'email'         => email,
                'phone'         => String.isNotBlank(phone) ? phone : '',
                'company'       => companyName,
                'extendedFields'=> new List<Object>()
            };

            Map<String, Object> payload = new Map<String, Object>{
                'serviceAppointment' => serviceAppt,
                'lead'               => lead
            };

            HttpResponse res = sfCallout(
                'POST',
                '/services/data/' + API_VERSION + '/connect/scheduling/service-appointments',
                JSON.serialize(payload)
            );

            if (res.getStatusCode() != 200 && res.getStatusCode() != 201) {
                throw new AuraHandledException('Booking API error ' + res.getStatusCode() + ': ' + res.getBody());
            }

            Map<String, Object> body   = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Object rootObj = body.containsKey('result') ? body.get('result') : body;
            Map<String, Object> result = (Map<String, Object>) rootObj;

            try {
                sendConfirmationEmail(email, firstName, companyName, serviceName, schedStartTime);
            } catch (Exception emailEx) {
                System.debug('Email send failed (non-fatal): ' + emailEx.getMessage());
            }

            return JSON.serialize(new Map<String, Object>{
                'serviceAppointmentId' => result.get('serviceAppointmentId'),
                'parentRecordId'       => result.get('parentRecordId')
            });
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Token + callout helpers ───────────────────────────────────────────────

    private static String getAccessToken() {
        if (cachedToken != null) {
            return cachedToken;
        }
        List<SchedulerCredential__mdt> creds = [
            SELECT AccessToken__c FROM SchedulerCredential__mdt
            WHERE DeveloperName = 'Default' LIMIT 1
        ];
        if (creds.isEmpty() || String.isBlank(creds[0].AccessToken__c)) {
            throw new AuraHandledException('Scheduler credential not configured. Run the token refresh script.');
        }
        cachedToken = creds[0].AccessToken__c;
        return cachedToken;
    }

    private static HttpResponse sfCallout(String method, String path, String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(BASE_URL + path);
        req.setMethod(method);
        req.setHeader('Authorization', 'Bearer ' + getAccessToken());
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        if (String.isNotBlank(body)) req.setBody(body);
        req.setTimeout(30000);
        return new Http().send(req);
    }

    private static void sendConfirmationEmail(
        String toEmail, String firstName, String companyName,
        String serviceName, String schedStartTime
    ) {
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new List<String>{ toEmail });
        mail.setSubject('Your ' + serviceName + ' Consultation is Confirmed');
        mail.setPlainTextBody(
            'Hi ' + firstName + ',\n\n' +
            'Your appointment has been confirmed!\n\n' +
            '  Vendor:    ' + companyName + '\n' +
            '  Service:   ' + serviceName + ' Consultation\n' +
            '  Time:      ' + schedStartTime + '\n' +
            '  Location:  In-Person · Gwinnett County, GA\n' +
            '  Duration:  60 minutes\n\n' +
            'A specialist will reach out to confirm your address and details.\n\n' +
            'Thank you for choosing Costco Home Services!'
        );
        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail });
    }
}
