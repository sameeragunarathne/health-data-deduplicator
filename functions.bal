// Copyright (c) 2025, WSO2 LLC. (http://www.wso2.org) All Rights Reserved.
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

import ballerina/ftp;
import ballerina/log;
import ballerina/time;
import ballerina/uuid;
import ballerinax/health.fhir.r4;
import ballerinax/health.fhir.r4utils.ccdatofhir;

function moveFileToErrorDirectory(string fileName, string fileContent) {
    ftp:Error? deletedFile = ftpClient->delete(path = incomingCcdaFileDir + fileName);
    if deletedFile is ftp:Error {
        log:printError("Error deleting file", deletedFile);
    }
    ftp:Error? failedFile = ftpClient->put(path = failedCcdaFileDir + fileName, content = fileContent);
    if failedFile is ftp:Error {
        log:printError("Error uploading file to error directory", failedFile);
    } else {
        log:printInfo("File moved to error directory successfully");
    }
}

function processCcdaFileContent(xml content) returns r4:Bundle|error? {

    r4:Bundle|r4:FHIRError ccdaToFhir = ccdatofhir:ccdaToFhir(content);
    if ccdaToFhir is r4:Bundle {
        log:printInfo("CCDA to FHIR conversion successful", convertedBundle = ccdaToFhir);
        return ccdaToFhir;
    } else {
        log:printError("Error converting CCDA to FHIR", ccdaToFhir);
        return error("Error converting CCDA to FHIR");
    }
}

function getDuplicateEntries(ResourceSummary[] resourceSummaries) returns DuplicateEntry[]|error {
    if deduplicationMode == exact {
        DuplicateEntry[] duplicateEntries = [];
        foreach ResourceSummary resourceSummary in resourceSummaries {
            boolean isDuplicate = check markDuplicateEntry(resourceSummary);
            if isDuplicate {
                DuplicateEntry duplicateEntry = {
                    resourceId: <string>resourceSummary.resourceId,
                    resourceType: resourceSummary.resourceType,
                    confidence: 1.0,
                    reasoning: "Exact match"
                };
                duplicateEntries.push(duplicateEntry);
                log:printDebug("Duplicate entry found", duplicateEntry = duplicateEntry);
            }
        }
        return duplicateEntries;
    } else if deduplicationMode == probabilistic {
        final time:Utc startTime = time:utcNow();
        final string sessionId = uuid:createType4AsString();
        do {
            string agentResponse = check deduplicateAgent->run(query = resourceSummaries.toJsonString(), sessionId = sessionId);
            agentResponse = re `${"```"}json`.replace(agentResponse, "");
            agentResponse = re `${"```"}`.replace(agentResponse, "");

            log:printDebug("FHIR Bundle duplicate identification successful", timeTaken = time:utcDiffSeconds(time:utcNow(), startTime).toString(), openAiAgentResponse = agentResponse, sessionId = sessionId);

            if agentResponse.trim().length() != 0 {
                final json jsonAgentResponse = check agentResponse.trim().fromJsonString();
                return check jsonAgentResponse.cloneWithType();
            }
        } on fail error err {
            log:printDebug("Unable to process agent response. Caused by, ", err, sessionId = sessionId);
        }
    }

    return [];
}

function constructResourceSummary(r4:Bundle bundle) returns ResourceSummary[]|error {
    ResourceSummary[] resourceSummaries = [];
    r4:BundleEntry[] entries = bundle.entry ?: [];
    boolean isPatientEntryFilled = false;

    foreach r4:BundleEntry entry in entries {
        if entry?.'resource is r4:Resource {
            r4:Resource 'resource = <r4:Resource>entry?.'resource;
            string? resourceId = 'resource.id;
            string? resourceType = 'resource.resourceType;
            ResourceSummary summary = {
                resourceId: resourceId,
                resourceType: <string>resourceType,
                fields: {}
            };
            json jsonResult = 'resource.toJson();
            match resourceType {
                "Patient" => {
                    if isPatientEntryFilled {
                        continue;
                    }
                    // For Patients, use identifier OR name + birthDate + gender
                    json|error identifier = jsonResult.identifier;
                    json|error name = jsonResult.name;
                    json|error birthDate = jsonResult.birthDate;
                    json|error gender = jsonResult.gender;
                    summary.fields = {
                        "identifier": identifier is json ? <json>identifier : (),
                        "name": name is json ? <json>name : (),
                        "birthDate": birthDate is json ? <json>birthDate : (),
                        "gender": gender is json ? <json>gender : ()
                    };
                    isPatientEntryFilled = true;
                }
                "Immunization" => {
                    // For Immunizations, use vaccineCode + identifier + occurrenceDateTime + patient
                    json|error vaccineCode = jsonResult.vaccineCode;
                    json|error identifier = jsonResult.identifier;
                    json|error occurrenceDateTime = jsonResult.occurrenceDateTime;
                    json|error patient = jsonResult.patient;
                    summary.fields = {
                        "vaccineCode": vaccineCode is json ? <json>vaccineCode : (),
                        "identifier": identifier is json ? <json>identifier : (),
                        "occurrenceDateTime": occurrenceDateTime is json ? <json>occurrenceDateTime : (),
                        "patient": patient is json ? <json>patient : ()
                    };
                }
                "DiagnosticReport" => {
                    // For DiagnosticReports, use code + subject + effectiveDateTime + identifier
                    json|error code = jsonResult.code;
                    json|error effectivePeriod = jsonResult.effectivePeriod;
                    json|error identifier = jsonResult.identifier;
                    summary.fields = {
                        "code": code is json ? <json>code : (),
                        "effectivePeriod": effectivePeriod is json ? <json>effectivePeriod : (),
                        "identifier": identifier is json ? <json>identifier : ()
                    };
                }
                "AllergyIntolerance" => {
                    // For AllergyIntolerances, use reaction + identifier + recordedDate
                    json|error reaction = jsonResult.reaction;
                    json|error identifier = jsonResult.identifier;
                    json|error recordedDate = jsonResult.recordedDate;
                    summary.fields = {
                        "reaction": reaction is json ? <json>reaction : (),
                        "identifier": identifier is json ? <json>identifier : (),
                        "recordedDate": recordedDate is json ? <json>recordedDate : ()
                    };
                }
                "MedicationRequest" => {
                    // MedicationRequest, use medicationCodeableConcept + dosageInstruction
                    json|error medicationCodeableConcept = jsonResult.medicationCodeableConcept;
                    json|error dosageInstruction = jsonResult.dosageInstruction;
                    summary.fields = {
                        "medicationCodeableConcept": medicationCodeableConcept is json ? <json>medicationCodeableConcept : (),
                        "dosageInstruction": dosageInstruction is json ? <json>dosageInstruction : ()
                    };
                }
                "Condition" => {
                    // For Conditions, use code + onsetDateTime + identifier + category
                    json|error code = jsonResult.code;
                    json|error onsetDateTime = jsonResult.onsetDateTime;
                    json|error identifier = jsonResult.identifier;
                    json|error category = jsonResult.category;
                    summary.fields = {
                        "code": code is json ? <json>code : (),
                        "onsetDateTime": onsetDateTime is json ? <json>onsetDateTime : (),
                        "identifier": identifier is json ? <json>identifier : (),
                        "category": category is json ? <json>category : ()
                    };
                }
            }
            resourceSummaries.push(summary);
        }
    }
    return resourceSummaries;
}

function markDuplicateEntry(ResourceSummary summary) returns boolean|error {
    string resourceSignature = "";
    //add match case for each resource type
    match summary.resourceType {
        "Patient" => {
            // For Patients, use identifier OR name + birthDate + gender
            map<json> fields = summary.fields;

            if fields.hasKey("identifier") {
                json? identifier = fields["identifier"];
                if identifier is json[] {
                    // Assuming the first identifier is the most relevant
                    // Check if the identifier has a value
                    if identifier.length() > 0 && identifier[0].value is string {
                        string identifierVal = check identifier[0].value;
                        resourceSignature = string `${resourceSignature}|${summary.resourceType.toString()}|${identifierVal}`;
                    }
                }
            } else if fields.hasKey("name") {
                json? name = fields["name"];
                if name is json[] {
                    // Assuming the first name is the most relevant
                    // Check if the name has a family name
                    if name[0].family is string {
                        string familyName = check name[0].family;
                        json|error givenNameArr = name[0].given;
                        // Check if the name has a given name
                        if givenNameArr is json[] {
                            resourceSignature = string `${resourceSignature}|${summary.resourceType.toString()}|${familyName}|${givenNameArr[0].toString()}`;
                        } else {
                            resourceSignature = string `${resourceSignature}|${summary.resourceType.toString()}|${familyName}`;
                        }
                    }
                }
                if fields.hasKey("birthDate") {
                    json? birthDate = fields["birthDate"];
                    if birthDate is json {
                        resourceSignature = string `${resourceSignature}|${birthDate.toString()}`;
                    }
                }
                if fields.hasKey("gender") {
                    json? gender = fields["gender"];
                    if gender is json {
                        resourceSignature = string `${resourceSignature}|${gender.toString()}`;
                    }
                }
            }
        }
        "Immunization" => {
            // For Immunizations, use vaccineCode + identifier + occurrenceDateTime + patient
            map<json> fields = summary.fields;
            if fields.hasKey("vaccineCode") {
                json? vaccineCode = fields["vaccineCode"];
                if vaccineCode is json[] {
                    // Assuming the first vaccineCode is the most relevant
                    // Check if the vaccineCode has a code
                    if vaccineCode[0].code is string {
                        string vaccineCodeVal = check vaccineCode[0].code;
                        resourceSignature = string `${resourceSignature}|${summary.resourceType.toString()}|${vaccineCodeVal}`;
                    }
                }
            }
            if fields.hasKey("identifier") {
                json? identifier = fields["identifier"];
                if identifier is json[] {
                    // Assuming the first identifier is the most relevant
                    // Check if the identifier has a value
                    if identifier.length() > 0 && identifier[0].value is string {
                        string identifierVal = check identifier[0].value;
                        resourceSignature = string `${resourceSignature}|${identifierVal}`;
                    }
                }
            }
            if fields.hasKey("occurrenceDateTime") {
                json? occurrenceDateTime = fields["occurrenceDateTime"];
                if occurrenceDateTime is json {
                    resourceSignature = string `${resourceSignature}|${occurrenceDateTime.toString()}`;
                }
            }
            if fields.hasKey("patient") {
                json? patient = fields["patient"];
                if patient is json {
                    resourceSignature = string `${resourceSignature}|${patient.toString()}`;
                }
            }
        }
        "DiagnosticReport" => {
            // For DiagnosticReports, use code + subject + effectiveDateTime + identifier
            map<json> fields = summary.fields;
            if fields.hasKey("code") {
                json? code = fields["code"];
                if code is json[] {
                    // Assuming the first code is the most relevant
                    // Check if the code has a coding
                    if code[0].coding is json[] {
                        json|error codingVal = code[0].coding;
                        if codingVal is json[] {
                            // Assuming the first coding is the most relevant
                            // Check if the coding has a code
                            if codingVal[0].code is string {
                                string codeVal = check codingVal[0].code;
                                resourceSignature = string `${resourceSignature}|${summary.resourceType.toString()}|${codeVal}`;
                            }
                        }
                    }
                }
            }
            if fields.hasKey("effectivePeriod") {
                json? effectivePeriod = fields["effectivePeriod"];
                if effectivePeriod is json {
                    resourceSignature = string `${resourceSignature}|${effectivePeriod.toString()}`;
                }
            }
            if fields.hasKey("identifier") {
                json? identifier = fields["identifier"];
                if identifier is json[] {
                    // Assuming the first identifier is the most relevant
                    // Check if the identifier has a value
                    if identifier.length() > 0 && identifier[0].value is string {
                        string identifierVal = check identifier[0].value;
                        resourceSignature = string `${resourceSignature}|${identifierVal}`;
                    }
                }
            }
        }
        "AllergyIntolerance" => {
            // For AllergyIntolerances, use reaction + identifier + recordedDate
            map<json> fields = summary.fields;
            if fields.hasKey("reaction") {
                json? reaction = fields["reaction"];
                if reaction is json[] {
                    // Assuming the first reaction is the most relevant
                    // Check if the reaction has a substance
                    if reaction[0].substance is json[] {
                        json|error substanceVal = reaction[0].substance;
                        if substanceVal is json[] {
                            // Assuming the first substance is the most relevant
                            // Check if the substance has a code
                            if substanceVal[0].code is string {
                                string substanceCode = check substanceVal[0].code;
                                resourceSignature = string `${resourceSignature}|${summary.resourceType.toString()}|${substanceCode}`;
                            }
                        }
                    }
                }
            }
            if fields.hasKey("identifier") {
                json? identifier = fields["identifier"];
                if identifier is json[] {
                    // Assuming the first identifier is the most relevant
                    // Check if the identifier has a value
                    if identifier.length() > 0 && identifier[0].value is string {
                        string identifierVal = check identifier[0].value;
                        resourceSignature = string `${resourceSignature}|${identifierVal}`;
                    }
                }
            }
            if fields.hasKey("recordedDate") {
                json? recordedDate = fields["recordedDate"];
                if recordedDate is json {
                    resourceSignature = string `${resourceSignature}|${recordedDate.toString()}`;
                }
            }
        }
        "MedicationRequest" => {
            // For MedicationRequests, use medicationCodeableConcept + dosageInstruction
            map<json> fields = summary.fields;
            if fields.hasKey("medicationCodeableConcept") {
                json? medicationCodeableConcept = fields["medicationCodeableConcept"];
                if medicationCodeableConcept is json[] {
                    // Assuming the first medicationCodeableConcept is the most relevant
                    // Check if the medicationCodeableConcept has a code
                    if medicationCodeableConcept[0].code is string {
                        string medicationCode = check medicationCodeableConcept[0].code;
                        resourceSignature = string `${resourceSignature}|${summary.resourceType.toString()}|${medicationCode}`;
                    }
                }
            }
            if fields.hasKey("dosageInstruction") {
                json? dosageInstruction = fields["dosageInstruction"];
                if dosageInstruction is json[] {
                    // Assuming the first dosageInstruction is the most relevant
                    // Check if the dosageInstruction has a text
                    if dosageInstruction[0].text is string {
                        string dosageText = check dosageInstruction[0].text;
                        resourceSignature = string `${resourceSignature}|${resourceSignature}|${dosageText}`;
                    }
                }
            }
        }
        "Condition" => {
            // For Conditions, use code + onsetDateTime + identifier + category
            map<json> fields = summary.fields;
            if fields.hasKey("code") {
                json? code = fields["code"];
                if code is json[] {
                    // Assuming the first code is the most relevant
                    // Check if the code has a coding
                    if code[0].coding is json[] {
                        json|error codingVal = code[0].coding;
                        if codingVal is json[] {
                            // Assuming the first coding is the most relevant
                            // Check if the coding has a code
                            if codingVal[0].code is string {
                                string codeVal = check codingVal[0].code;
                                resourceSignature = string `${resourceSignature}|${summary.resourceType.toString()}|${codeVal}`;
                            }
                        }
                    }
                }
            }
            if fields.hasKey("onsetDateTime") {
                json? onsetDateTime = fields["onsetDateTime"];
                if onsetDateTime is json {
                    resourceSignature = string `${resourceSignature}|${onsetDateTime.toString()}`;
                }
            }
            if fields.hasKey("identifier") {
                json? identifier = fields["identifier"];
                if identifier is json[] {
                    // Assuming the first identifier is the most relevant
                    // Check if the identifier has a value
                    if identifier[0].value is string {
                        string identifierVal = check identifier[0].value;
                        resourceSignature = string `${resourceSignature}|${identifierVal}`;
                    }
                }
            }
        }
    }
    if resourceSignature == "" {
        return false;
    }
    if resourceSignatureList.indexOf(resourceSignature) == -1 {
        resourceSignatureList.push(resourceSignature);
        return false;
    }
    return true;
}

function removeDuplicatesFromBundle(DuplicateEntry[] entries, r4:Bundle bundle) returns r4:Bundle {
    final r4:BundleEntry[] bundleEntries = bundle.entry ?: [];
    final r4:BundleEntry[] deduplicatedBundleEntries = bundleEntries.clone();

    foreach DuplicateEntry duplicateEntry in entries {
        foreach r4:BundleEntry bundleEntry in bundleEntries {
            if bundleEntry?.'resource is r4:Resource {
                r4:Resource resourceResult = <r4:Resource>bundleEntry?.'resource;
                string? resourceId = resourceResult.id;
                if resourceId is string {
                    if duplicateEntry.resourceId == resourceId {
                        int? index = deduplicatedBundleEntries.lastIndexOf(bundleEntry);
                        if index is int {
                            _ = deduplicatedBundleEntries.remove(index);
                        }
                    }
                }
            }
        }
    }

    return {'type: "transaction", 'entry: deduplicatedBundleEntries};
}

