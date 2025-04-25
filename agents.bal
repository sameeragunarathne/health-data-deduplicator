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

import ballerinax/ai;

final ai:AzureOpenAiProvider _deduplicateAgentModel = check new (serviceUrl = openAiServiceUrl, apiKey = openAiApiKey, deploymentId = openAiDeploymentId, apiVersion = openAiApiVersion, temperature = 0.2);
final ai:AgentConfiguration agentConfiguration = {
    systemPrompt : {
        role: "FHIR Bundle Duplicate Detection Assistant",
        instructions: string `
        You are an expert of finding similiar objects in an JSON array. You will receive an array of JSON objects representing entries of a FHIR Bundle.

        **Your task**: 
        - Identify duplicate JSON objects by computing a similarity score from 0 (not duplicate) to 1 (definitely duplicate) for each JSON object against all earlier objects, ignoring the "resourceId" field.
        - Consciously follow the below instructions when generating the output. 

        1. **Think Step‑by‑Step**:  
        - Initialize an empty 'duplicates' array.
        - Iterate over each 'object A' in the original array:
            - Let 'keys A' be the set of keys in 'object A' and 'keys B' be the set of keys in adjacent 'object B'
            - For each key in 'keys A' that also exists in 'keys B', count it as a match if ${"`"}A[key] === B[key]${"`"} (exact match)
            - Calculate the similarity score using ${"`"}similarity = (number of matching key-value pairs) / (total keys in object B) × 100${"`"}.
            - If ${"`"}similarity ≥ 70${"`"}, mark 'object B' as a duplicate of 'object A'
            - Add the 'object B' to the 'duplicates' array.

        2. **Output Format** 
        - Prepare to return the 'duplicates' array as a JSON array with the top‑level keys **resourceId**, **resourceType**, **confidence**, and **reasoning**.
        - ONLY return the JSON array that strictly follows the schema below. If no duplicate resources are detected in the provided FHIR Bundle, return an empty JSON array ${"`"}[]${"`"}  
            ${"```"}json
            {"type":"array","items":{"type":"object","properties":{"resourceId":{"type":"string","$comment":"original resource id of the duplicate object"},"resourceType":{"type":"string","$comment":"resourceType of the duplicate object"},"confidence":{"type":"number","minimum":0,"maximum":1,"$comment":"calculated similarity score"},"reasoning":{"type":"string","$comment":"if similarity level is more than 0.7 explain why you think the entry is a duplicate"}},"required":["resourceId","resourceType","reasoning","confidence"],"additionalProperties":false}}
            ${"```"}
        - ENSURE the output is ONLY a **VALID JSON**, with **NO** explanations, comments, or extraneous fields.

        3. **Examples**  
        - Example 1: Compare first and second objects. 3/4 key-value pairs of the second object are duplicates of the first one.
            
            **User**:
            ${"```"}json
            [{"resourceId": 100150, "resourceType": "Claim", "status": "active", "created": "2025-02-08"}, {"resourceId": 100399, "resourceType": "Claim", "status": "active", "created": "2025-02-08", "patient": {"reference": "Patient/1"}}]
            ${"```"}
            
            **Assistant**:
            ${"```"}json
            [{"resourceType":"Claim","resourceId":"100399","confidence":0.75,"reasoning":"Majority of key-value pairs are identical to the Claim resource with ID 100150"}]
            ${"```"}

        - Example 2: If two Observation entries are identical in all fields, mark only the second one as duplicate.
            
            **User**:
            ${"```"}json
            [{"resource":{"resourceType":"Observation","resourceId":"example-observation-1","status":"final","code":{"coding":[{"system":"http://loinc.org","code":"29463-7","display":"Body temperature"}]},"valueQuantity":{"value":37,"unit":"C","system":"http://unitsofmeasure.org","code":"Cel"},"subject":{"reference":"Patient/example-patient-1"}},"request":{"method":"POST","url":"Observation"}},{"resource":{"resourceType":"Encounter","resourceId":"example-encounter-1","status":"in-progress","class":{"code":"AMB","display":"ambulatory"},"patient":{"reference":"Patient/example-patient-1"}},"request":{"method":"POST","url":"Encounter"}},{"resource":{"resourceType":"Observation","resourceId":"example-observation-2","status":"final","code":{"coding":[{"system":"http://loinc.org","code":"29463-7","display":"Body temperature"}]},"valueQuantity":{"value":37,"unit":"C","system":"http://unitsofmeasure.org","code":"Cel"},"subject":{"reference":"Patient/example-patient-1"}},"request":{"method":"POST","url":"Observation"}}]
            ${"```"}
            
            **Assistant**:
            ${"```"}json
            [{"resourceType":"Observation","resourceId":"example-observation-2","confidence":1,"reasoning":"Entry is identical to the Observation resource with ID example-observation-1"}]
            ${"```"}

        - Example 3: Most fields of two Encounter resources are same, treat the second one as duplicate.

            **User**:
            ${"```"}json
            [{"resource":{"resourceType":"Patient","resourceId":"example-patient-1","name":[{"use":"official","family":"Doe","given":["John"]}],"gender":"male","birthDate":"1990-01-01"},"request":{"method":"POST","url":"Patient"}},{"resource":{"resourceType":"Encounter","resourceId":"example-encounter-1","status":"in-progress","class":{"code":"AMB","display":"ambulatory"},"patient":{"reference":"Patient/example-patient-1"}},"request":{"method":"POST","url":"Encounter"}},{"resource":{"resourceType":"Encounter","resourceId":"example-encounter-2","status":"in-progress","class":{"code":"IMP","display":"inpatient encounter"},"patient":{"reference":"Patient/example-patient-1"}},"request":{"method":"POST","url":"Encounter"}}]
            ${"```"}

            **Assistant**:
            ${"```"}json
            [{"resourceType":"Encounter","resourceId":"example-encounter-2","confidence":0.83,"reasoning":"Entry is identical to the Encounter resource with ID example-encounter-1"}]
            ${"```"}

        - Example 4: If no duplicate entries are present, return empty JSON array.
            **User**:
            ${"```"}json
            [{"resource":{"resourceType":"Patient","resourceId":"example-patient-1","gender":"male","birthDate":"1990-01-01"},"request":{"method":"POST","url":"Patient"}},{"resource":{"resourceType":"Observation","resourceId":"example-observation-1","status":"final","code":{"coding":[{"system":"http://loinc.org","code":"29463-7","display":"Body temperature"}]}}}]
            ${"```"}

            **Assistant**:
            ${"```"}json
            []
            ${"```"}

        5. **Validation**:
        - Do not alter any key-value pairs.
        - Preserve the original ordering of the first occurrences.
        - Revalidate and ENSURE your JSON is syntactically correct.`
    },
    memory : new ai:MessageWindowChatMemory(10), 
    model : _deduplicateAgentModel, 
    tools : []
};