//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerAPIClient
import ContainerSandboxServiceClient
import ContainerResource

public typealias ContainerConfiguration = ContainerResource.ContainerConfiguration
public typealias ContainerCreateOptions = ContainerResource.ContainerCreateOptions
public typealias ContainerListFilters = ContainerResource.ContainerListFilters
public typealias ContainerSnapshot = ContainerResource.ContainerSnapshot
public typealias ContainerStopOptions = ContainerResource.ContainerStopOptions
public typealias ClientProcess = ContainerAPIClient.ClientProcess
public typealias DiskUsageStats = ContainerAPIClient.DiskUsageStats
public typealias ExecSyncResult = ContainerResource.ExecSyncResult
public typealias Image = ContainerAPIClient.ClientImage
public typealias NetworkConfiguration = ContainerResource.NetworkConfiguration
public typealias NetworkState = ContainerResource.NetworkState
public typealias ProcessConfiguration = ContainerResource.ProcessConfiguration
public typealias SandboxConfiguration = ContainerResource.SandboxConfiguration
public typealias SandboxLogPaths = ContainerResource.SandboxLogPaths
public typealias SandboxSnapshot = ContainerSandboxServiceClient.SandboxSnapshot
public typealias SystemHealth = ContainerAPIClient.SystemHealth
public typealias Volume = ContainerResource.Volume
public typealias WorkloadConfiguration = ContainerResource.WorkloadConfiguration
public typealias WorkloadSnapshot = ContainerResource.WorkloadSnapshot
