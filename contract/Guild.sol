// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title Guild
 * @dev The ultimate on-chain entity for a Web3 guild, designed for the NexusLabs ecosystem.
 * @author NexusLabs Assistant
 * @notice This production-ready version features a fully integrated, on-chain multi-signature
 * treasury, pausable functionality, a permanent ban list, and other security enhancements.
 */
contract Guild is ERC721, ERC721URIStorage, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // =============================================
    // SECTION: STATE & CONFIGURATION
    // =============================================

    bytes32 public constant GUILD_MASTER_ROLE = keccak256("GUILD_MASTER_ROLE");
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER_ROLE");
    bytes32 public constant MEMBER_ROLE = keccak256("MEMBER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    enum PassportStatus { Inactive, Active, Revoked }
    
    struct Proposal {
        uint256 id;
        address proposer;
        address to;
        uint256 amount;
        address tokenContract; // address(0) for native currency
        string description;
        uint256 deadline;
        bool executed;
        bool cancelled;
        mapping(address => bool) approvals;
        uint256 approvalCount;
    }

    uint256 public approvalThreshold;
    uint256 public nextProposalId;
    mapping(uint256 => Proposal) public proposals;

    mapping(address => bool) public banned;
    string public logoURI;
    string public bannerURI;
    uint256 private _nextTokenId;
    mapping(address => uint256) public memberToPassportId;
    mapping(uint256 => PassportStatus) public passportStatuses;

    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;
    mapping(address => uint256) public stakedBalances;
    uint256 public totalStaked;
    
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    
    bool public governanceActive = false;
    mapping(address => uint8) public allianceStatus;
    
    // --- Events ---
    event LeadershipTransferred(address indexed previousLeader, address indexed newLeader);
    event ApprovalThresholdUpdated(uint256 newThreshold);
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer, string description, uint256 deadline);
    event ProposalApproved(uint256 indexed proposalId, address indexed approver);
    event ProposalExecuted(uint256 indexed proposalId);
    event ProposalCancelled(uint256 indexed proposalId);
    event MemberBanned(address indexed user);
    event LogoUpdated(string newLogoURI);
    event BannerUpdated(string newBannerURI);
    event GovernanceActivated();
    event RewardsNotified(uint256 reward, uint256 duration);
    event RewardPaid(address indexed user, uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event AllianceProposed(address indexed toGuild);
    event MemberAdded(address indexed user);
    event MemberRemoved(address indexed user);
    event GuildLeft(address indexed user);
    event PassportMinted(address indexed user, uint256 indexed tokenId);
    event PassportRevoked(uint256 indexed tokenId, address indexed member);

    constructor(
        string memory name,
        string memory symbol,
        address initialGuildMaster,
        address _stakingTokenAddress,
        address _rewardTokenAddress,
        uint256 _initialApprovalThreshold
    ) ERC721(name, symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, initialGuildMaster);
        _grantRole(GUILD_MASTER_ROLE, initialGuildMaster);
        _grantRole(OFFICER_ROLE, initialGuildMaster);
        _grantRole(PAUSER_ROLE, initialGuildMaster);
        
        require(_initialApprovalThreshold > 0, "Threshold must be positive");
        approvalThreshold = _initialApprovalThreshold;
        stakingToken = IERC20(_stakingTokenAddress);
        rewardToken = IERC20(_rewardTokenAddress);
        
        _addMember(initialGuildMaster);
    }
    
    receive() external payable {}

    // =============================================
    // SECTION: LEADERSHIP & MEMBERSHIP
    // =============================================

    function transferLeadership(address newLeader) public whenNotPaused {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Only the current leader can transfer ownership.");
        require(hasRole(OFFICER_ROLE, newLeader), "New leader must be an existing officer.");
        
        address oldLeader = msg.sender;
        _grantRole(DEFAULT_ADMIN_ROLE, newLeader);
        _grantRole(GUILD_MASTER_ROLE, newLeader);
        _grantRole(PAUSER_ROLE, newLeader);
        _revokeRole(DEFAULT_ADMIN_ROLE, oldLeader);
        _revokeRole(GUILD_MASTER_ROLE, oldLeader);
        _revokeRole(PAUSER_ROLE, oldLeader);
        
        emit LeadershipTransferred(oldLeader, newLeader);
    }

    function addMember(address user) public whenNotPaused onlyRole(GUILD_MASTER_ROLE) {
        require(!banned[user], "Address is banned from this guild.");
        _addMember(user);
    }
    
    function _addMember(address user) internal {
        require(!hasRole(MEMBER_ROLE, user), "User is already a member");
        _grantRole(MEMBER_ROLE, user);

        uint256 tokenId;
        unchecked {
            tokenId = _nextTokenId++;
        }
        memberToPassportId[user] = tokenId;
        passportStatuses[tokenId] = PassportStatus.Active;
        _safeMint(user, tokenId);

        emit MemberAdded(user);
        emit PassportMinted(user, tokenId);
    }
    
    function banMember(address user) public whenNotPaused onlyRole(GUILD_MASTER_ROLE) {
        require(hasRole(MEMBER_ROLE, user), "User is not a member");
        banned[user] = true;
        _revokeAndRemove(user);
        emit MemberBanned(user);
    }

    function removeMember(address user) public whenNotPaused onlyRole(GUILD_MASTER_ROLE) {
        require(hasRole(MEMBER_ROLE, user), "User is not a member");
        _revokeAndRemove(user);
    }

    function leaveGuild() public whenNotPaused onlyRole(MEMBER_ROLE) {
        _revokeAndRemove(msg.sender);
        emit GuildLeft(msg.sender);
    }

    function renounceOfficer() public {
        require(hasRole(OFFICER_ROLE, msg.sender), "Not an officer");
        require(!hasRole(GUILD_MASTER_ROLE, msg.sender), "Guild Master cannot renounce officer role.");
        _revokeRole(OFFICER_ROLE, msg.sender);
    }
    
    function _revokeAndRemove(address user) internal {
        uint256 tokenId = memberToPassportId[user];
        if (passportStatuses[tokenId] != PassportStatus.Revoked) {
            passportStatuses[tokenId] = PassportStatus.Revoked;
            emit PassportRevoked(tokenId, user);
            _burn(tokenId);
        }

        _revokeRole(MEMBER_ROLE, user);
        if (hasRole(OFFICER_ROLE, user)) {
            _revokeRole(OFFICER_ROLE, user);
        }
        emit MemberRemoved(user);
    }

    function promoteToOfficer(address member) public whenNotPaused onlyRole(GUILD_MASTER_ROLE) {
        require(hasRole(MEMBER_ROLE, member), "User is not a member.");
        _grantRole(OFFICER_ROLE, member);
    }

    // =============================================
    // SECTION: TREASURY & GOVERNANCE
    // =============================================
    
    function createWithdrawalProposal(
        address to,
        uint256 amount,
        address tokenContract,
        string memory description,
        uint256 duration
    ) public whenNotPaused onlyRole(OFFICER_ROLE) returns (uint256) {
        require(to != address(0), "Cannot send to the zero address");
        require(amount > 0, "Amount must be greater than zero");
        require(duration > 0, "Duration must be positive");

        uint256 proposalId = nextProposalId++;
        uint256 deadline = block.timestamp + duration;
        
        Proposal storage newProposal = proposals[proposalId];
        newProposal.id = proposalId;
        newProposal.proposer = msg.sender;
        newProposal.to = to;
        newProposal.amount = amount;
        newProposal.tokenContract = tokenContract;
        newProposal.description = description;
        newProposal.deadline = deadline;
        
        emit ProposalCreated(proposalId, msg.sender, description, deadline);
        return proposalId;
    }
    
    function approveProposal(uint256 proposalId) public whenNotPaused onlyRole(OFFICER_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Already executed");
        require(!proposal.cancelled, "Cancelled");
        require(block.timestamp < proposal.deadline, "Expired");
        require(!proposal.approvals[msg.sender], "Already approved");
        proposal.approvals[msg.sender] = true;
        proposal.approvalCount++;
        emit ProposalApproved(proposalId, msg.sender);
    }

    function executeProposal(uint256 proposalId) public whenNotPaused onlyRole(OFFICER_ROLE) nonReentrant {
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Proposal already executed");
        require(!proposal.cancelled, "Proposal was cancelled");
        require(block.timestamp < proposal.deadline, "Proposal has expired");
        require(proposal.approvalCount >= approvalThreshold, "Not enough approvals");

        proposal.executed = true;

        if (proposal.tokenContract == address(0)) {
            require(address(this).balance >= proposal.amount, "Insufficient native currency");
            (bool success, ) = proposal.to.call{value: proposal.amount}("");
            require(success, "Native currency transfer failed");
        } else {
            IERC20(proposal.tokenContract).safeTransfer(proposal.to, proposal.amount);
        }

        emit ProposalExecuted(proposalId);
    }
    
    function cancelProposal(uint256 proposalId) public whenNotPaused onlyRole(OFFICER_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        require(!proposal.executed, "Proposal already executed");
        require(!proposal.cancelled, "Proposal already cancelled");
        
        proposal.cancelled = true;
        emit ProposalCancelled(proposalId);
    }
    
    function setApprovalThreshold(uint256 newThreshold) public onlyRole(GUILD_MASTER_ROLE) {
        require(newThreshold > 0, "Threshold must be greater than zero");
        approvalThreshold = newThreshold;
        emit ApprovalThresholdUpdated(newThreshold);
    }
    
    function setLogoURI(string memory _newLogoURI) public onlyRole(GUILD_MASTER_ROLE) {
        logoURI = _newLogoURI;
        emit LogoUpdated(_newLogoURI);
    }

    function setBannerURI(string memory _newBannerURI) public onlyRole(GUILD_MASTER_ROLE) {
        bannerURI = _newBannerURI;
        emit BannerUpdated(_newBannerURI);
    }

    // =============================================
    // SECTION: PAUSABLE & STAKING
    // =============================================

    function pause() public onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() public onlyRole(PAUSER_ROLE) { _unpause(); }

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + (((min(block.timestamp, periodFinish) - lastUpdateTime) * rewardRate * 1e18) / totalStaked);
    }

    function earned(address account) public view returns (uint256) {
        return (stakedBalances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }
    
    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function notifyRewardAmount(uint256 reward, uint256 duration) public whenNotPaused onlyRole(GUILD_MASTER_ROLE) updateReward(address(0)) {
        require(reward > 0 && duration > 0, "Invalid reward/duration");
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / duration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / duration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;
        emit RewardsNotified(reward, duration);
    }
    
    function claimReward() public nonReentrant whenNotPaused updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            uint256 availableRewards = rewardToken.balanceOf(address(this));
            uint256 amountToPay = min(reward, availableRewards);
            if (amountToPay > 0) {
                rewards[msg.sender] -= amountToPay;
                rewardToken.safeTransfer(msg.sender, amountToPay);
                emit RewardPaid(msg.sender, amountToPay);
            }
        }
    }

    function stake(uint256 amount) public nonReentrant whenNotPaused updateReward(msg.sender) {
        require(amount > 0, "Cannot stake zero");
        totalStaked += amount;
        stakedBalances[msg.sender] += amount;
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }
    
    function unstake(uint256 amount) public nonReentrant whenNotPaused updateReward(msg.sender) {
        require(amount > 0, "Cannot unstake zero");
        require(stakedBalances[msg.sender] >= amount, "Insufficient staked balance");
        claimReward();
        totalStaked -= amount;
        stakedBalances[msg.sender] -= amount;
        stakingToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }
    
    function emergencyWithdraw() public nonReentrant {
        uint256 balance = stakedBalances[msg.sender];
        require(balance > 0, "No staked balance");
        stakedBalances[msg.sender] = 0;
        totalStaked -= balance;
        rewards[msg.sender] = 0;
        userRewardPerTokenPaid[msg.sender] = rewardPerToken();
        stakingToken.safeTransfer(msg.sender, balance);
        emit EmergencyWithdraw(msg.sender, balance);
    }

    // =============================================
    // SECTION: SOULBOUND NFT & VIEW FUNCTIONS
    // =============================================

    function isPassportActive(uint256 tokenId) public view returns (bool) {
        return passportStatuses[tokenId] == PassportStatus.Active;
    }
    
    function _beforeTokenTransfer(address from, address to, uint256 firstTokenId, uint256 batchSize) internal virtual override {
        require(from == address(0) || to == address(0), "Guild Passport is non-transferable (Soulbound)");
        super._beforeTokenTransfer(from, to, firstTokenId, batchSize);
    }

    function approve(address, uint256) public virtual override {
        require(false, "Guild Passport is non-transferable");
    }

    function setApprovalForAll(address, bool) public virtual override {
        require(false, "Guild Passport is non-transferable");
    }

    function _update(address to, uint256 tokenId, address auth) internal virtual override(ERC721, ERC721URIStorage) returns (address) {
        return super._update(to, tokenId, auth);
    }

    function _transfer(address from, address to, uint256 tokenId) internal virtual override(ERC721, ERC721URIStorage) {
        super._transfer(from, to, tokenId);
    }
    
    function tokenURI(uint256 tokenId) public view virtual override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }
    
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC721URIStorage, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function hasApproved(uint256 proposalId, address user) external view returns (bool) {
        return proposals[proposalId].approvals[user];
    }
}
