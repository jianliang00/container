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

#if os(macOS)
import Testing

@testable import ContainerXPC

struct XPCClientSessionDisconnectStateTests {
    @Test func unexpectedDisconnectIsStickyAndDeliveredOnce() async {
        let state = XPCClientSessionDisconnectState()
        let counter = Counter()

        #expect(!state.register { await counter.increment() })
        let handlers = state.disconnect()
        #expect(handlers.count == 1)
        for handler in handlers {
            await handler()
        }

        #expect(state.disconnect().isEmpty)
        #expect(state.register { await counter.increment() })
        await counter.increment()
        #expect(await counter.value == 2)
    }

    @Test func intentionalCloseSuppressesDisconnectAndLateHandlers() {
        let state = XPCClientSessionDisconnectState()

        state.close()

        #expect(state.disconnect().isEmpty)
        #expect(!state.register {})
    }

    @Test func disconnectRemainsStickyAfterClose() {
        let state = XPCClientSessionDisconnectState()

        #expect(state.disconnect().isEmpty)
        state.close()

        #expect(state.register {})
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}
#endif
