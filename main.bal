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
import ballerina/io;
import ballerina/log;
import ballerinax/health.fhir.r4;

// FTP Client configuration
final ftp:ClientConfiguration clientConfig = {
    protocol: ftp:SFTP,
    host: ftpHost,
    port: ftpPort,
    auth: {
        credentials: {
            username: ftpUsername,
            password: ftpPassword
        }
    }
};

// Initialize FTP client
final ftp:Client ftpClient;

r4:Bundle finalBundle = {'type: "transaction", 'entry: []};
string[] resourceSignatureList = [];

function init() returns error? {
    do {
        ftpClient = check new (clientConfig);
    } on fail error err {
        log:printError("Failed to initialize clients. Caused by, ", err);
        return error("Failed to initialize clients. Caused by, ", err);
    }
}

public function main() returns error? {
    do {
        ftp:FileInfo[]|error fileList = ftpClient->list(path = incomingCcdaFileDir);
        if fileList is ftp:FileInfo[] {
            log:printInfo(string `Found ${fileList.length().toString()} files in FTP location`);
            if fileList.length() == 0 {
                log:printInfo("No files found in FTP location");
                return;
            }
            boolean isPatientAdded = false;
            foreach ftp:FileInfo addedFile in fileList {
                string fileName = addedFile.name;
                log:printInfo(string `CCDA File added: ${fileName}`);
                stream<byte[] & readonly, io:Error?> fileStream = check ftpClient->get(path = addedFile.pathDecoded);
                string fileContent = "";
                log:printInfo("-------- Started processing file content --------");
                check fileStream.forEach(function(byte[] & readonly chunk) {
                    string|error content = string:fromBytes(chunk);
                    if content is string {
                        fileContent += content;
                    } else {
                        log:printError("Error converting chunk to string", content);
                        return;
                    }
                });

                log:printInfo("-------- Finished consuming file content --------");
                log:printInfo("File content: ", fileContent = fileContent);
                if fileContent.startsWith("<?xml version=\"1.0\" encoding=\"UTF-8\"?>") {
                    fileContent = fileContent.substring(38);
                }
                xml|error xmlContent = xml:fromString(fileContent);
                if xmlContent is error {
                    log:printError("Invalid CCDA file recieved", xmlContent);
                    _ = moveFileToErrorDirectory(fileName, fileContent);
                    return;
                }
                log:printDebug("File content: ", fileContent = xmlContent);
                r4:Bundle|error? processResponse = processCcdaFileContent(xmlContent);
                if processResponse is error {
                    log:printError("Error processing file content", processResponse);
                    _ = moveFileToErrorDirectory(fileName, fileContent);
                    return;
                } else {
                    r4:Bundle processedBundle = <r4:Bundle>processResponse;
                    r4:BundleEntry[]? entry = processedBundle.entry;
                    if entry is r4:BundleEntry[] {
                        // iterate through the entries and add to finalBundle
                        foreach r4:BundleEntry bundleEntry in entry {
                            if bundleEntry?.'resource is r4:Resource {
                                r4:Resource resourceResult = <r4:Resource>bundleEntry?.'resource;
                                string resourceType = resourceResult.resourceType;
                                if resourceType.equalsIgnoreCaseAscii("Patient") {
                                    if !isPatientAdded {
                                        isPatientAdded = true;
                                        log:printDebug("Adding Patient resource to final bundle");
                                        (<r4:BundleEntry[]>finalBundle.entry).push(bundleEntry);
                                    }
                                } else {
                                    (<r4:BundleEntry[]>finalBundle.entry).push(bundleEntry);
                                }
                            }
                        }
                    }

                    ftp:Error? deletedFile = ftpClient->delete(path = addedFile.pathDecoded);
                    if deletedFile is ftp:Error {
                        log:printError("Error deleting file", deletedFile);
                    }
                    ftp:Error? processedFile = ftpClient->put(path = processedCcdaFileDir + fileName, content = fileContent);
                    if processedFile is ftp:Error {
                        log:printError("Error moving file to processed directory", processedFile);
                    } else {
                        log:printInfo("File moved to processed directory successfully");
                    }
                    log:printInfo("File processed successfully");
                }
            }
            log:printInfo("-------- FHIR Bundle constructed --------");
            log:printInfo("Pre Deduplication Final Bundle: ", bundleContent = finalBundle);

            ResourceSummary[]|error resourceSummaryResult = constructResourceSummary(finalBundle);
            if resourceSummaryResult is ResourceSummary[] {
                log:printInfo("-------- FHIR Bundle resource summary constructed --------");
                log:printInfo("Resource Summary: ", resourceSummary = resourceSummaryResult);

                DuplicateEntry[] duplicatedEntries = check getDuplicateEntries(resourceSummaryResult);
                log:printInfo("-------- FHIR Bundle deduplicate entries identified --------");
                log:printInfo("Deduplicate Entries: ", deduplicatedContent = duplicatedEntries);

                finalBundle = removeDuplicatesFromBundle(duplicatedEntries, finalBundle);
                log:printInfo("Post Deduplication Final Bundle: ", bundleContent = finalBundle);
            } else {
                log:printError("Error constructing resource summary", resourceSummaryResult);
            }
        }
    } on fail error err {
        log:printError("Error in periodic file check", err);
    }
}
