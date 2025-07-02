# Sovereign_Guilds_Registry
Guild Identity & The Nexus Registry
"Get your Sovereign Guild ID and be immortalized on the blockchain forever!"
The Sovereign Guild Identity system is a revolutionary framework for creating and managing Web3 guilds. It provides the tools for guilds to evolve from simple social groups into permanent, autonomous, on-chain organizations with a verifiable history and a self-sustaining economy.

This project introduces the Nexus Registry, a dApp that allows guild leaders to forge a "Sovereign Guild Identity" by deploying a unique, feature-complete smart contract (Guild.sol) on the Ronin blockchain. This contract serves as the guild's permanent on-chain entity, managing its members, treasury, and governance in a trustless and transparent manner.

This system is designed to work in tandem with GuildHQ, the central management dashboard for the NexusLabs ecosystem. While GuildHQ provides a fast and gasless experience for day-to-day operations, the Nexus Registry provides the on-chain authority and permanence that serious guilds require.

Core Features
The Guild.sol smart contract is the heart of the system, providing each registered guild with a powerful suite of native, on-chain features:

Sovereign Identity: Each guild becomes a unique smart contract with its own permanent address on the blockchain, serving as its undeniable identity.

Secure Treasury Vault: The Contract Acts As a multi-signature wallet, ensuring that guild funds are controlled collectively by its leadership, not by a single individual.

Soulbound Membership Passports: The contract acts as its own ERC-721 collection, minting non-transferable (soulbound) NFT "passports" to members. This creates a verifiable and tamper-proof record of membership and status.

On-Chain Roles & History: Manages a complete on-chain ledger of members and their roles (Guild Master, Officer, Member). Promotions, departures, and leadership transfers are all recorded as permanent on-chain events, creating a "living history" for the guild.

Decentralized Staking Pool: Includes a built-in staking mechanism where members can stake a designated token (e.g., $Ron, $AXS) to earn rewards, allowing them to invest directly in their guild's success.

Hardened Security: The contract has been designed with security as a priority, incorporating:

Pausable Functionality: An emergency-stop mechanism for critical functions like staking and rewards.

Re-entrancy Guards: Protection against common smart contract exploits.

Permanent Ban List: A feature to permanently ban malicious users from rejoining.

Transferable Leadership: A secure, on-chain process for a Guild Master to transfer ownership to a designated officer, ensuring the guild's long-term viability.

User Autonomy: Features like leaveGuild() and renounceOfficer() empower members and leaders to manage their own status within the guild.

The Technology
This project consists of two main components: the smart contracts and the front-end dApp for interaction.

1. The Smart Contracts
Guild.sol: The all-in-one smart contract that represents the on-chain guild entity. It inherits from audited OpenZeppelin contracts for ERC721, AccessControl, Pausable, and ReentrancyGuard.

GuildFactory.sol: A lightweight factory contract that is deployed once. Its sole purpose is to deploy new instances of the Guild.sol contract for each guild that registers.

2. The Front-End (nexus_registry.html)
A self-contained HTML file that serves as a prototype dApp for interacting with the factory contract. It provides a user interface for:

Deploying a new Guild.sol contract.

Calling the administrative functions on a deployed guild contract, such as deploying a treasury vault, transferring leadership, and managing members.

Simulating user interactions with clear success confirmations via a modern toast notification system.

Getting Started
Prerequisites
A Web3 wallet compatible with the Ronin network (e.g., Ronin Wallet).

RON tokens for gas fees.

Node.js and npm/yarn for dependency management.

Foundry or Hardhat for smart contract deployment.

Deployment
Deploy Gnosis Safe Contracts: If they are not already available on the target network (e.g., Ronin Mainnet or Saigon Testnet), you must first deploy the official Gnosis Safe contracts, including the GnosisSafe.sol master copy and the GnosisSafeProxyFactory.sol.

Deploy the GuildFactory.sol:

Open the GuildFactory.sol file.

In the constructor, provide the required addresses for the staking token, the deployed Gnosis Safe proxy factory, and the Gnosis Safe singleton.

Compile and deploy this contract to the blockchain. Note the deployed address of the factory.

Configure the Front-End:

Open the nexus_registry.html file.

Inside the JavaScript section, locate the placeholder variables for contract addresses and ABIs.

Update these placeholders with the deployed address of your GuildFactory.sol contract and its ABI.

Running the Front-End
Simply open the nexus_registry.html file in any modern web browser.

Connect your wallet when prompted.

Use the "Deploy New Guild Contract" form to create your on-chain guild. Once the transaction is confirmed, the management dashboard will appear, allowing you to interact with your newly deployed Guild.sol contract.

Contract API Summary
The Guild.sol contract exposes a rich API for developers to build upon. Here is a summary of the public functions available on every deployed guild contract.

View Functions (Read-Only)
name(): Returns the guild's name.

symbol(): Returns the symbol for the passport NFTs.

logoURI() / bannerURI(): Returns the URIs for the guild's visual identity.

treasuryVault(): Returns the address of the deployed Gnosis Safe treasury.

hasRole(role, account): Checks if a user has a specific role.

isPassportActive(tokenId): Checks if a member's passport is currently active.

earned(account): Checks pending staking rewards for a user.

...and more for checking staked balances, governance status, etc.

Transactional Functions (State-Changing)
Leadership: transferLeadership(newLeader), renounceOfficer()

Membership: addMember(user), removeMember(user), leaveGuild(), banMember(user)

Treasury & Visuals: deployTreasuryVault(owners, threshold), setLogoURI(uri), setBannerURI(uri)

Staking: stake(amount), unstake(amount), claimReward(), emergencyWithdraw()

Pausable Controls: pause(), unpause()
