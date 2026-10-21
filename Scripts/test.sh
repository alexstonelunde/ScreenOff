#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
    Sources/ScreenOffCore/DisplayPolicy.swift Sources/ScreenOffCore/WatchdogRules.swift \
    Tests/PolicyTests.swift -o .build/policy-tests
.build/policy-tests
xcrun swiftc -swift-version 5 -D CONTROLLER_TEST -module-cache-path .build/module-cache \
    Sources/ScreenOffCore/*.swift Sources/ScreenOff/RecoveryGuard.swift \
    Sources/ScreenOff/DisplayController.swift Tests/RecoverySimulation.swift Tests/RecoveryControllerTests.swift \
    -o .build/recovery-tests
.build/recovery-tests
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
    Sources/ScreenOffCore/*.swift Tests/SupervisorTests.swift -o .build/supervisor-tests
.build/supervisor-tests
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
    Sources/ScreenOffCore/DisplayPolicy.swift Sources/ScreenOffCore/DisplayTransaction.swift \
    Tests/TransactionFixture.swift -o .build/transaction-fixture
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
    Sources/ScreenOffCore/DisplayPolicy.swift Sources/ScreenOffCore/DisplayTransaction.swift \
    Tests/TransactionTests.swift -o .build/transaction-tests
.build/transaction-tests "$PWD/.build/transaction-fixture"

xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
    Sources/ScreenOffCore/DisplayRoleOverride.swift Tests/DisplayRoleTests.swift -o .build/display-role-tests
.build/display-role-tests

xcrun swiftc -swift-version 5 -D ROLE_HELPER_TEST -module-cache-path .build/module-cache \
    Sources/ScreenOffCore/DisplayRoleOverride.swift Sources/ScreenOffCore/DisplayPolicy.swift \
    Sources/ScreenOffCore/BuiltInRecoveryTarget.swift Sources/ScreenOffDisplayRole/RoleHelper.swift \
    Tests/RoleHelperTests.swift -o .build/role-helper-tests
.build/role-helper-tests

xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
    Sources/ScreenOffCore/DisplayEnvironment.swift Sources/ScreenOffCore/WatchdogRules.swift \
    Tests/SessionPolicyTests.swift -o .build/session-policy-tests
.build/session-policy-tests

xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
    Sources/ScreenOffCore/DisplayPolicy.swift Sources/ScreenOffCore/RecoveryCommand.swift \
    Tests/RecoveryQueryFixture.swift -o .build/recovery-query-fixture
xcrun swiftc -swift-version 5 -module-cache-path .build/module-cache \
    Sources/ScreenOffCore/DisplayPolicy.swift Sources/ScreenOffCore/RecoveryCommand.swift \
    Tests/RecoveryCommandTests.swift -o .build/recovery-command-tests
.build/recovery-command-tests "$PWD/.build/recovery-query-fixture" "$PWD/Sources/ScreenOff/App.swift"
