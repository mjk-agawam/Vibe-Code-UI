/**
 * After a ServiceAppointment is inserted, asynchronously creates a Zoom
 * meeting via the Zoom REST API and writes the join URL to MeetingJoinUrl__c.
 *
 * Uses @future (callout=true) so the API call never blocks the booking.
 * When Teams integration is enabled later, swap ZoomMeetingService for
 * TeamsMeetingService — no other changes needed.
 */
trigger ServiceAppointmentTeams on ServiceAppointment (after insert) {
    for (ServiceAppointment sa : Trigger.new) {
        if (String.isBlank(sa.MeetingJoinUrl__c)) {
            ZoomMeetingService.createMeetingForAppointment(sa.Id);
        }
    }
}
