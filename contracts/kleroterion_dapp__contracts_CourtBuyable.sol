pragma solidity ^0.4.6;


contract Token {
    /* This is a slight change to the ERC20 base standard.
    function totalSupply() constant returns (uint256 supply);
    is replaced with:
    uint256 public totalSupply;
    This automatically creates a getter function for the totalSupply.
    This is moved to the base contract since public getter functions are not
    currently recognised as an implementation of the matching abstract
    function by the compiler.
    */
    /// total amount of tokens
    uint256 public totalSupply;

    /// @param _owner The address from which the balance will be retrieved
    /// @return The balance
    function balanceOf(address _owner) constant returns (uint256 balance);

    /// @notice send `_value` token to `_to` from `msg.sender`
    /// @param _to The address of the recipient
    /// @param _value The amount of token to be transferred
    /// @return Whether the transfer was successful or not
    function transfer(address _to, uint256 _value) returns (bool success);

    /// @notice send `_value` token to `_to` from `_from` on the condition it is approved by `_from`
    /// @param _from The address of the sender
    /// @param _to The address of the recipient
    /// @param _value The amount of token to be transferred
    /// @return Whether the transfer was successful or not
    function transferFrom(address _from, address _to, uint256 _value) returns (bool success);

    /// @notice `msg.sender` approves `_addr` to spend `_value` tokens
    /// @param _spender The address of the account able to transfer the tokens
    /// @param _value The amount of wei to be approved for transfer
    /// @return Whether the approval was successful or not
    function approve(address _spender, uint256 _value) returns (bool success);

    /// @param _owner The address of the account owning tokens
    /// @param _spender The address of the account able to transfer the tokens
    /// @return Amount of remaining tokens allowed to spent
    function allowance(address _owner, address _spender) constant returns (uint256 remaining);

    event Transfer(address indexed _from, address indexed _to, uint256 _value);
    event Approval(address indexed _owner, address indexed _spender, uint256 _value);
}


// Note, we assume totalSupply < 2^256-1
// NOTE: All time interactions are for test and demo purpose only.
// TODO: Manage the time states of the contract.
contract Court is Token {
    /** Distribute tokens on initialization.
     *  To be replaced by a crowdfunding.
     */
    function Court(address[] accounts, uint256[] tokens){
        if (accounts.length!=tokens.length)
            throw;
        for (uint256 i = 0; i < accounts.length; i++){
            balances[accounts[i]]+=tokens[i];
            totalSupply+=tokens[i];
        }

        session=1; // Session starts at 1 in order to keep 0 as a special value.

        // Push a null dispute in order to make dispute starts at 1.
        // This allows interacting contracts to assume that the default value 0 indicates that there is no dispute yet.
        // This will save more gaz than the gaz overhead in the constructor which will only be called once.
        disputes.length++;

    }


    // **************************** //
    // *       Token part         * //
    // **************************** //

    function transfer(address _to, uint256 _value) returns (bool success) {
        // Note that (balances[msg.sender] >= _value + atStake[msg.sender]) is not sufficient as it could overflow.
        if (balances[msg.sender] >= _value && _value > 0 && !blocked(msg.sender) && balances[msg.sender] >= _value + atStake[msg.sender]) {
            balances[msg.sender] -= _value;
            balances[_to] += _value;
            Transfer(msg.sender, _to, _value);
            return true;
        } else { return false; }
    }

    function transferFrom(address _from, address _to, uint256 _value)  returns (bool success) {
        if (balances[_from] >= _value && allowed[_from][msg.sender] >= _value && _value > 0 && !blocked(_from) && balances[_from] >= _value + atStake[_from]) {
            balances[_to] += _value;
            balances[_from] -= _value;
            allowed[_from][msg.sender] -= _value;
            Transfer(_from, _to, _value);
            return true;
        } else { return false; }
    }

    function balanceOf(address _owner) constant returns (uint256 balance) {
        return balances[_owner];
    }

    function approve(address _spender, uint256 _value) returns (bool success) {
        allowed[msg.sender][_spender] = _value;
        Approval(msg.sender, _spender, _value);
        return true;
    }

    function allowance(address _owner, address _spender) constant returns (uint256 remaining) {
      return allowed[_owner][_spender];
    }

    mapping (address => uint256) balances;
    mapping (address => mapping (address => uint256)) allowed;

    // **************************** //
    // *       Court part         * //
    // **************************** //

    mapping (address => uint256) public atStake; // Max number of tokens which can be lost. Those tokens are blocked

    uint256 public session; // Current session of the court
    uint256 public endLastSession; // Time when last session finished

    mapping (address => uint256) public arbitralSession;       // Last session the tokens were activated for arbitration.
    mapping (address => uint256) public arbitralSegmentStart; // Start of the segment of tokens for arbitration during arbitralSession.
    mapping (address => uint256) public arbitralSegmentEnd;   // End of the segment of tokens for arbitration during arbitralSession.
    uint256 public arbitralSegmentPosition;                    // Last position used in the arbitral token circle.

    mapping (address => uint256) public jurySession;           // Last session the tokens were activated for jury.
    mapping (address => uint256) public jurySegmentStart;     // Start of the segment of tokens for jury during arbitralSession.
    mapping (address => uint256) public jurySegmentEnd;       // End of the segment of tokens for jury during arbitralSession.
    uint256 public jurySegmentPosition;                        // Last position used in the jury token circle.

    // WARNING those values are for test purpose only
    uint256 public minArbitralToken=1000;                      // Minimum number of tokens to be arbitrator.
    uint256 public minJuryToken=1000;                          // Minimum of tokens drawn for jury.
    uint256 public partAtStakeDivisor=5;                       // (1/partAtStakeDivisor) is the maximum proportion of tokens which can be lost.

    struct Dispute {
        Arbitrable arbitratedContract; // Contract to be arbitrated.
        uint256 session; // Session for the dispute to be resolved. High values are special values.
        uint256 appeals; // Number of appeals for the dispute.
        uint256 r; // Random number for the dispute.
        uint256 voteA;
        uint256 voteB;
        Vote[][] voters; // In the form of voters[appeals][votePosition].
        mapping (address => uint256) hasVoted; // Last session the account has voted.
    }
    // Special values for dispute session
    uint256 EXECUTABLE = uint256(-1);
    uint256 EXECUTED   = uint256(-2);

    // TODO: Replace appeals with voters.length if it consumes less gaz.

    struct Vote {
        address account;
        uint256 stakeA;
        uint256 stakeB;
    }


    Dispute[] public disputes;

    // TODO: Verify and set the right types



    /** Return true if the tokens of account are blocked.
     *  Tokens are blocked if they are activated for arbitration or for the jury system in the current session.
     *  @param account The account to be checked if blocked.
     */
    function blocked(address account) constant returns(bool){
        if (session == arbitralSession[account] || session == jurySession[account])
            return true;
        else
            return false;
    }


    /** Active the tokens for arbitration.
     *  Tokens must not have already be activated for arbitration during this session.
     *  The activation must be open.
     *  The account calling the function must have the tokens it wants to activate.
     *  The number account calling this function must have at least minArbitralToken.
     *  @param tokens Number of tokens to be activated.
     */
    function activateTokensForArbitration(uint256 tokens){
        if (arbitralSession[msg.sender]==session || !activationOpen() || balances[msg.sender]<tokens || tokens<minArbitralToken) // Verify that the tokens can be activated
            throw;

        arbitralSession[msg.sender]=session; // The tokens are activated for this session.

        arbitralSegmentStart[msg.sender]=arbitralSegmentPosition; // Update the positions.
        arbitralSegmentPosition+=tokens;
        arbitralSegmentEnd[msg.sender]=arbitralSegmentPosition;
    }

    /** Active the tokens for the jury system.
     *  Tokens must not have already be activated for the jury system during this session.
     *  The activation must be open.
     *  The account calling the function must have the tokens it wants to activate.
     *  The minimum number of tokens to be activated is minJuryToken. This is to avoid vote flooding which would lead to increased gaz cost.
     *  @param tokens Number of tokens to be activated.
     */
    function activateTokensForJury(uint256 tokens){
        if (jurySession[msg.sender]==session || !activationOpen() || balances[msg.sender]<tokens || tokens < minJuryToken) // Verify that the tokens can be activated
            throw;

        jurySession[msg.sender]=session; // The tokens are activated for this session.

        jurySegmentStart[msg.sender]=jurySegmentPosition; // Update the positions.
        jurySegmentPosition+=tokens;
        jurySegmentEnd[msg.sender]=jurySegmentPosition;
    }

    /** Return true if account is the arbiter of the dispute.
     *  @param account Account which could be a member of the dispute.
     *  @param r       Random number of the dispute.
     *  Note that the function throws if arbitralSegmentPosition==0 which happens when no tokens have been activated for arbitration.
     */
    function drawnArbiter(address account, uint256 r) constant returns(bool){
        if (arbitralSession[account]!=session) // No tokens activated for this session
            return false;
        uint256 drawnPosition=r % arbitralSegmentPosition;
        if (arbitralSegmentStart[account]<=drawnPosition && drawnPosition<arbitralSegmentEnd[account])
            return true;
        else
            return false;
    }



    /** Return the number of drawn tokens belonging to account.
     *  @param account Account to be return the number of drawn tokens.
     *  @param r       Random number of the dispute.
     *  @param t       Total number of tokens to be drawn for the appeal.
     *  Note that the function throws if jurySegmentPosition==0 which happens when no tokens have been activated for the jury system.
     */
    function drawnTokens(address account, uint256 r, uint256 t) constant returns(uint256) {
        if (jurySession[account]!=session) // No tokens activated for this session
            return 0;
        if (t>=jurySegmentPosition) // All the court is drawn
            return jurySegmentEnd[account]-jurySegmentStart[account];

        uint256 startDrawnSegment=r % jurySegmentPosition;
        uint256 endDrawnSegment=startDrawnSegment+t;
        uint256 leftIntersection;
        uint256 rightIntersection;
        if (endDrawnSegment<=jurySegmentPosition){  // We don't wrap arround
            leftIntersection=(jurySegmentEnd[account] < endDrawnSegment ? jurySegmentEnd[account] : endDrawnSegment);
            rightIntersection=(jurySegmentStart[account] > startDrawnSegment ? jurySegmentStart[account] : startDrawnSegment);
            return (leftIntersection < rightIntersection ? rightIntersection - leftIntersection : 0);
        }
        else { // We wrap arround
            endDrawnSegment-=jurySegmentPosition;
            leftIntersection=(jurySegmentStart[account] > startDrawnSegment ? jurySegmentStart[account] : startDrawnSegment);
            rightIntersection=(jurySegmentEnd[account] < jurySegmentPosition ? jurySegmentEnd[account] : jurySegmentPosition);
            return (leftIntersection < rightIntersection ? rightIntersection - leftIntersection : 0)
            + (endDrawnSegment > jurySegmentStart[account] ? endDrawnSegment-jurySegmentStart[account] : 0);
        }
    }

    /** To be called by Arbitrable contracts.
     *  @param r Random seed given by the arbitrable contract.
     *  @return disputeID The ID of the dispute. Notice that it starts at 1.
     *  TODO: Payment of the arbitration fees.
     */
    function createDispute(uint256 r) payable returns(uint256 disputeID) {
        if (!disputeOpen()) // Can't create a dispute now.
            throw;
        disputeID=disputes.length++;
        Dispute dispute=disputes[disputeID];
        dispute.arbitratedContract=Arbitrable(msg.sender);
        dispute.session=session;
        dispute.r=r;
        dispute.voters.length++;

        return disputeID;
    }

    /** Arbitrate a dispute.
     *  @param disputeID ID of the dispute to be arbitrated.
     *  @param voteA True to rule A. False to rule B.
     */
    function arbitrate(uint256 disputeID, bool voteA){
        Dispute dispute=disputes[disputeID];
        uint256 stake=minArbitralToken/partAtStakeDivisor;

        if (!drawnArbiter(msg.sender,dispute.r)// Verify that the sender was the drawn arbiter.
            || dispute.voteA > 0 // Verify that it hasn't been ruled yet.
            || dispute.voteB > 0
            || dispute.appeals != 0 // Verify it is a first instance
            || dispute.session != session  // Verify that the dispute is a dispute of this session.
            || !voteOpen()) // The arbitration is closed or not open yet.
            throw;


        atStake[msg.sender]+=stake; // Add tokens at Stake.
        dispute.voters[dispute.appeals].push(Vote({  // Add it in the list of voters.
            account:msg.sender,
            stakeA:voteA ? stake : 0,
            stakeB:voteA ? 0 : stake
        }));
        // Cast the decision of the arbiter
        if (voteA)
            dispute.voteA=1;
        else
            dispute.voteB=1;

    }

    /** Execute the ruling given by the court.
     *  The ruling must be executable.
     *  Note that this function can throw due to the arbitrated contract throwing.
     *  @param disputeID ID of the dispute to have its ruling enforced.
     */
    function untrustedExecuteRuling(uint256 disputeID){
        Dispute dispute=disputes[disputeID];
        if (dispute.session != EXECUTABLE)
            throw;
        dispute.session=EXECUTED; // Indicates that the dispute is resovled.

        if (dispute.voteA>dispute.voteB) // A wins.
            dispute.arbitratedContract.ruleA(disputeID);
        else // B wins
            dispute.arbitratedContract.ruleB(disputeID);
    }

    /** Appeal a ruling.
     *  TODO: Payment of the arbitration fees.
     *  @param disputeID ID of the dispute to be appealed.
     */
    function appealRuling(uint256 disputeID, uint256 r) payable {
        Dispute dispute=disputes[disputeID];
        if (dispute.session != session-1 // The dispute was not ruled before this session.
            || !appealOpen() // It's too late to appeal.
            || dispute.arbitratedContract != msg.sender // Not called by the arbitrated contract.
            || (minJuryToken * (2**(dispute.appeals+1)) > jurySegmentPosition && dispute.voteA!=dispute.voteB)) // Number of drawn tokens would be more than twice the number of activated tokens. No more appeal possible, unless the last ruling was tied.
            throw;

        dispute.voteA=0; // Reset votes.
        dispute.voteB=0;
        dispute.session=session; // Dispute will be arbitrable for this new session
        dispute.appeals+=1;
        dispute.voters.length++;
    }

    /** Make a ruling as a jury member.
     *  @param disputeID ID of the dispute to be arbitrated.
     *  @param voteA True to rule A. False to rule B.
     *  TODO: Switch to a system with committed votes.
     */
    function voteRuling(uint256 disputeID, bool voteA) {
        Dispute dispute=disputes[disputeID];
        uint256 stake;
        if (dispute.hasVoted[msg.sender]==session // Has already voted for the session
            || !voteOpen()) // The vote is closed or not open yet.
            throw;

        uint256 votingRights=drawnTokens(msg.sender,dispute.r,(2**(dispute.appeals)) * minJuryToken);
        dispute.hasVoted[msg.sender]=session; // Has voted
        if (voteA)
            dispute.voteA+=votingRights;
        else
            dispute.voteB+=votingRights;

        stake=votingRights/partAtStakeDivisor;
        atStake[msg.sender]+=stake; // Add tokens at stake

        dispute.voters[dispute.appeals].push(Vote({  // Add it in the list of voters.
            account:msg.sender,
            stakeA:voteA ? stake : 0,
            stakeB:voteA ? 0 : stake
        }));
    }

    /** Execute the repartition of tokens.
     *  This function works in 1 shot.
     *  minJuryToken is here to make it impossible for an attacker to make this function run out of gaz on purpose.
     *  However it can happen in cas of an high number of appeal.
     *  @param disputeID ID of the dispute.
     *  TODO: Implement function doing it in multiple shot in order to avoid being blocked by the gaz limit.
     */
    function executeTokenRepartition(uint256 disputeID){
        Dispute dispute=disputes[disputeID];
        if (dispute.session >= session // The dispute was not solved before this session or is in a special state.
            || !executionOpen() // Execution can't be done yet.
            || dispute.voteA == dispute.voteB)   // The vote is tied or the arbiter was inactive.
            throw;

        bool winnerA = dispute.voteA > dispute.voteB;

        // Token repartition for jury members
        for (;dispute.voters.length>1;--dispute.voters.length){
            uint256 j;
            uint256 divider=0;
            uint256 totalToSplit=0;
            uint256 remainingToSplit=0;
            uint256 stake=0;
            uint256 lostStake=0;
            uint256 wonStake=0;
            Vote memory vote;

            for (j=0;j<dispute.voters[dispute.voters.length-1].length;++j){ // Compute the parts
                vote=dispute.voters[dispute.voters.length-1][j];
                stake=vote.stakeA+vote.stakeB;
                atStake[vote.account]-=stake; // Remove tokens at Stake such that they can be moved again.
                if (winnerA){
                    divider+=vote.stakeA;
                    lostStake=vote.stakeB<balances[vote.account] ? vote.stakeB : balances[vote.account]; // Can't loose more tokens than they have.

                } else {
                    divider+=vote.stakeB;
                    lostStake=vote.stakeA<balances[vote.account] ? vote.stakeA : balances[vote.account];
                }
                balances[vote.account]-=lostStake; // Remove the lost tokens. Note that it can't underflow due to taking the minimum.
                totalToSplit+=lostStake; // And put them in a common pot.
            }
            remainingToSplit=totalToSplit;

            if (divider!=0) // If divider is 0, there is nothing to give and we split this loop to avoid dividing by 0.
                for (j=0;j<dispute.voters[dispute.voters.length-1].length;++j){
                    vote=dispute.voters[dispute.voters.length-1][j];
                    if (winnerA)
                        wonStake=(vote.stakeA*totalToSplit)/divider; // TO DO: Make sure that it can't overflow.
                    else
                        wonStake=(vote.stakeB*totalToSplit)/divider;
                    remainingToSplit-=wonStake;
                    balances[vote.account]+=wonStake;
                }
            balances[this]+=remainingToSplit; // Give the remaining tokens due to division to the court itself in order to keep the number of token fixed.
        }

        // Token repartition for arbiter.
        if(dispute.voters[0].length>0) {
            vote=dispute.voters[0][0];
            if (winnerA)
                lostStake=vote.stakeB<balances[vote.account] ? vote.stakeB : balances[vote.account];
            else
                lostStake=vote.stakeA<balances[vote.account] ? vote.stakeA : balances[vote.account];

            atStake[vote.account]-=vote.stakeA+vote.stakeB; // Remove tokens at Stake such that they can be moved again.
            balances[vote.account]-=lostStake; // For now just give it to the court as the fee system is not there yet.
            balances[this]+=lostStake;

            --dispute.voters.length;// Clean up in order to get some gas back.
        }

        dispute.session=EXECUTABLE; // Now the ruling can be executed.
    }

    /** Make inactive arbitrators loose some tokens.
     *  TODO: Send back the caller of the function a few ethers to cover gas cost.
     *  @param accounts List of accounts to be penalized.
     *  @param disputeIDs List of disputes the accounts failed to arbitrate.
     */
    function penalizeInactiveArbitrators(address[] accounts, uint256[] disputeIDs) {
        if (!penalizationOpen()) // Too early or too late to penalize.
            throw;
        uint256 penalty=minArbitralToken/partAtStakeDivisor;
        for (uint256 i=0;i<accounts.length;++i){
            Dispute dispute=disputes[disputeIDs[i]];
            if (!drawnArbiter(accounts[i],dispute.r) // This arbitrator was not chosen.
                || dispute.hasVoted[accounts[i]]==session) // The arbitrator has voted.
                throw;
            uint256 toBeLost=penalty<balances[accounts[i]] ? penalty : balances[accounts[i]]; // Make sure not to loose more than the balance.
            balances[accounts[i]]-=toBeLost; // Give some of his tokens to the court.
            balances[this]+=toBeLost;
            dispute.hasVoted[accounts[i]]=session; // Set him as if he had voted to prevent penalizing him multiple times.
        }
    }

    /** Make inactive jury members loose some tokens.
     *  TODO: Send back the caller of the function a few ethers to cover gas cost.
     *  @param accounts List of accounts to be penalized.
     *  @param disputeIDs List of disputes the accounts failed to vote.
     */
    function penalizeInactiveJuries(address[] accounts, uint256[] disputeIDs) {
        if (!penalizationOpen()) // Too early or too late to penalize.
            throw;
        for (uint256 i=0;i<accounts.length;++i){
            Dispute dispute=disputes[disputeIDs[i]];
            uint256 tokens=drawnTokens(accounts[i],dispute.r,(2**(dispute.appeals)) * minJuryToken);
            if (tokens==0 // This jury member was not chosen.
                || dispute.hasVoted[accounts[i]]==session) // The jury member has voted.
                throw;
            uint256 penalty=tokens/partAtStakeDivisor;
            uint256 toBeLost=penalty<balances[accounts[i]] ? penalty : balances[accounts[i]]; // Make sure not to loose more than the balance.
            balances[accounts[i]]-=toBeLost; // Give some of his tokens to the court.
            balances[this]+=toBeLost;
            dispute.hasVoted[accounts[i]]=session; // Set him as if he had voted to prevent penalizing him multiple times.
        }
    }


    // **************************** //
    // *        Time  part        * //
    // **************************** //

    /** TO BE IMPLEMENTED
     *  For now can be called by anyone.
     */
    function nextSession() {
        session++; // Open a new session.
        arbitralSegmentPosition=0; // Reset the positions for both jury and arbiters.
        jurySegmentPosition=0;
        endLastSession=now;
    }

    /** TO BE IMPLEMENTED
     *  For now it is always open.
     *  In the future, it will only be opened at the begining of sessions.
     */
    function activationOpen() constant returns(bool) {
        return true;
    }

    /** TO BE IMPLEMENTED
     *  For now it is always open.
     *  In the future, it will be only opened after the activation is closed.
     */
    function disputeOpen() constant returns(bool) {
        return true;
    }

    /** TO BE IMPLEMENTED
     *  For now it is always open.
     *  In the future, it will be open after the disputes are closed.
     */
     function voteOpen() constant returns(bool) {
        return true;
    }

    /** TO BE IMPLEMENTED
     *  For now they are always open.
     *  In the future, the will be only opened.
     */
    function appealOpen() constant returns(bool) {
        return true;
    }

    /** TO BE IMPLEMENTED
     *  For now they are always open.
     *  In the future, they will be open before the execution is.
     */
    function penalizationOpen() constant returns(bool){
        return true;
    }

    /** TO BE IMPLEMENTED
     *  For now they are always open.
     *  In the future, they will be open a few times after appeals are closed.
     */
    function executionOpen() constant returns(bool){
        return true;
    }



    // **************************** //
    // *     Constant Getters     * //
    // **************************** //

    /** Get the number of appeals of a dispute.
     *  Notice that it can throw if disputeID does not exist.
     *  @param disputeID ID of the dispute.
     */
    function getAppeals(uint256 disputeID) constant returns (uint256) {
        return disputes[disputeID].appeals;
    }

    /** Return the last appeal account has voted.
     *  Notice that it can throw if disputeID does not exist.
     *  @param disputeID ID of the dispute.
     *  @param account account who voted or not.
     */
    function getHasVoted(uint256 disputeID, address account) constant returns (uint256){
        return disputes[disputeID].hasVoted[account];
    }

    /** Return the stake in a vote.
     *  Note that it can throw if disputeID does not exist or appeal is greater than the number of appeals.
     *  @param disputeID ID of the dispute.
     *  @param appeal Appeal to return the votes, or 0 to return the vote of the arbitrator.
     *  @param voteID ID of the vote.
     *  @param stakeA true to to return the stake in A. False to return the stake in B.
     */
    function getVoteStake(uint256 disputeID, uint256 appeal, uint256 voteID, bool stakeA) constant returns(uint256){
        if (stakeA)
            return disputes[disputeID].voters[appeal][0].stakeA;
        else
            return disputes[disputeID].voters[appeal][0].stakeB;
    }

    /** Return the list of votes.
     *  Note that it can throw if disputeID does not exist or appeal is greater than the number of appeals.
     *  @param disputeID ID of the dispute.
     *  @param appeal Appeal to return the votes, or 0 to return the vote of the arbitrator.
     *  @param voteID ID of the vote.
     */
    function getVoteAccount(uint256 disputeID, uint256 appeal, uint256 voteID) constant returns(address){
        return disputes[disputeID].voters[appeal][0].account;
    }

    /** Return the amount of tokens activated for arbitration in the current session.
     *  @param account Account to return the number of activated tokens.
     */
    function activatedArbitrationTokens(address account) constant returns(uint256){
        if (arbitralSession[account]!=session)
            return 0;
        else
            return arbitralSegmentEnd[account]-arbitralSegmentStart[account];
    }

    /** Return the amount of tokens activated for jury in the current session.
     *  @param account Account to return the number of activated tokens.
     */
    function activatedJuryTokens(address account) constant returns(uint256){
        if (jurySession[account]!=session)
            return 0;
        else
            return jurySegmentEnd[account]-jurySegmentStart[account];
    }

    /** Return the number of disputes.
     *  @return nb number of disputes.
     */
    function nbDispute() constant returns(uint nb) {return disputes.length;}

}

// TODO Refactor all the time logic of those contracts.

/*
Virtual Contract to be artibrated by the court.
*/
contract Arbitrable {
    Court court;
    function Arbitrable(Court _court){
        court=_court;
    }

    modifier onlyCourt {if (msg.sender!=address(court)) throw; _;}

    /** Function the court will call to execute ruling A.
     *  In most cases, this function should have the modifier onlyCourt.
     */
    function ruleA(uint256 disputeID);

    /** Function the court will call to execute ruling B.
     *  In most cases, this function should have the modifier onlyCourt.
     */
    function ruleB(uint256 disputeID);

}

contract TwoPartyArbitrable is Arbitrable {

    // Varaibles set during contract construction //
    address public partyA;
    address public partyB;
    uint256 public timeToReac; // Must be way lower than timeForAppeal/2

    bytes32 public hashRandom;
    uint256 public secondRandom;
    address public requestCreator; // Creator of the dispute request or appeal request
    uint256 public disputeID;
    uint256 public nextAppeals; // Number next appeal will be.

    uint256 public lastAction;

    /// Can only be called by a party of the contract
    modifier onlyParty(){
        if (msg.sender != partyA && msg.sender != partyB)
            throw;
        _;
    }

    /// Cannot be called by account
    modifier notAccount(address account){
        if (account==msg.sender)
            throw;
        _;
    }

    modifier onlyAccount(address account){
        if (account!=msg.sender)
            throw;
        _;
    }

    /** Contract with two parties to be arbitrated. The party A is the contract creator.
     *  @param _court Address of the court.
     *  @param _partyB Party B.
     *  @param _timeToReac Reaction time of the other party.
     */
    function TwoPartyArbitrable(Court _court, address _partyB, uint256 _timeToReac) Arbitrable(_court) {
        partyA=msg.sender;
        partyB=_partyB;
        timeToReac=_timeToReac;
    }

    function ruleA(uint256 disputeID) onlyCourt { executeRulingA(disputeID); }
    function ruleB(uint256 disputeID) onlyCourt { executeRulingB(disputeID); }

    /// Set the state at ruledA. The court call this function if A is ruled.
    function executeRulingA(uint256 _disputeID) private {
        if (_disputeID!=disputeID) // Not arbitrating the current dispute.
            throw;
        actionA(_disputeID);
        clean();
    }

    /// Set the state at ruledB. The court call this function if B is ruled.
    function executeRulingB(uint256 _disputeID) private {
        if (_disputeID!=disputeID) // Not arbitrating the current dispute.
            throw;
        actionB(_disputeID);
        clean();
    }

    function actionA(uint256 _disputeID) private;
    function actionB(uint256 _disputeID) private;

    /** Clean everything after a ruling is executed.
     */
    function clean() private {
        hashRandom=0;
        secondRandom=0;
        requestCreator=0;
        disputeID=0;
        nextAppeals=0;
    }

    /** Create an internal request for ruling.
     *  @param _hashRandom Hash of the random number of the requesting party.
     */
    function request(bytes32 _hashRandom) onlyParty {
        if (hashRandom!=0 // A request has already been made.
            || disputeID!=0) // The dispute is already submitted.
            throw;
        hashRandom=_hashRandom;
        requestCreator=msg.sender;
        lastAction=now;
    }

    /** Make a counter request.
     *  @param _secondRandom Random number of the counter-requesting party
     */
    function counterRequest(uint256 _secondRandom) onlyParty notAccount(requestCreator) {
        if (hashRandom==0 // No request
            || secondRandom!=0 // Counter-request already done.
            || disputeID!=0)  // The dispute is already submitted.
            throw;
        secondRandom=_secondRandom;
        lastAction=now;
    }

    /** Create the dispute.
     *  Can only be called after a counter-request.
     *  @param firstRandom Random number of the counter-requesting party
     */
    function createDispute(uint256 firstRandom) onlyAccount(requestCreator) {
        if (sha3(firstRandom)!=hashRandom // Value not corresponding to the commitment.
            || secondRandom==0 // Lack of counter request.
            || disputeID!=0) // The dispute has already been created.
            throw;
        disputeID=court.createDispute(firstRandom ^ secondRandom); // Create a dispute with a random number being a XOR of both of them
        nextAppeals=1; // Next appeal will be the first.
        hashRandom=0;
        secondRandom=0;
        requestCreator=0;
        lastAction=now;
    }

    // Note that this function is not needed for the smart contract to execute but is provided there in order to make tests using only the smart contract.
    function hash(uint256 n) constant returns(bytes32) {return sha3(n);}

    /** Set the state in the absence of reaction of the other party.
     *  @param executeA True if A to be executed. False if B to be executed.
     */
    function executeDueToInactivity(bool executeA) onlyParty {
        if (now - lastAction < timeToReac) // Reaction time to reached.
            throw;
        if ((msg.sender==requestCreator && secondRandom==0) // The requesting party can set the state if the other one has not given its random number
            || (msg.sender!=requestCreator && secondRandom!=0 && disputeID==0 && court.voteOpen()) // The counter-requesting party can set the state if the requesting party has not called createDispute in times.
            ||  msg.sender!=requestCreator && disputeID!=0 && !court.appealOpen()){ // The party making the appeal failed to submit the appeal in time.
            if (executeA)
                executeRulingA(disputeID);
            else
                executeRulingB(disputeID);
        }
        else
            throw;
    }


    /** Appeal a ruling.
     *  Notice that you must do it early enought as there will be timeToReac for the other party before the dispute is completed.
     *  @param _hashRandom Hash of the random number of the requesting party.
     */
    function appeal(bytes32 _hashRandom) onlyParty{
        if (hashRandom!=0 // An appeal request has already been made.
            || court.getAppeals(disputeID) + 1 != nextAppeals) // There is already an appeal submitted.
            throw;
        hashRandom=_hashRandom;
        requestCreator=msg.sender;
        lastAction=now;
    }

    /** Make a counter appeal.
     *  @param _secondRandom Random number of the counter-requesting party
     */
    function counterAppeal(uint256 _secondRandom) onlyParty notAccount(requestCreator) {
        if (hashRandom==0 // No appeal
            || secondRandom!=0 // Counter-appeal already done.
            || court.getAppeals(disputeID) + 1 != nextAppeals)  // There is already an appeal submitted.
            throw;
        secondRandom=_secondRandom;
        lastAction=now;
    }

    /** Launch the appeal request
     *
     *  @param firstRandom Random number of the counter-requesting party
     */
    function createAppeal(uint256 firstRandom) onlyAccount(requestCreator) {
        if (sha3(firstRandom)!=hashRandom // Value not corresponding to the commitment.
            || secondRandom==0 // Lack of counter appeal.
            || court.getAppeals(disputeID) + 1 != nextAppeals) // The dispute is already submitted.
            throw;
        court.appealRuling(disputeID,firstRandom ^ secondRandom); // Create an appeal with a random number being a XOR of both of them.
        nextAppeals+=1;

        hashRandom=0;
        secondRandom=0;
        requestCreator=0;
        lastAction=now;
    }

}

/// This contract is a simple example where arbitration only change a state varible
contract ExampleTwoPartyArbitrable is TwoPartyArbitrable {
    enum State {created, ruledA, ruledB}
    State public state; // The state can be set by the court.

    function ExampleTwoPartyArbitrable(Court _court, address _partyB, uint256 _timeToReac) TwoPartyArbitrable(_court,_partyB,_timeToReac) {}

    function actionA(uint256 _disputeID) private {state=State.ruledA;}
    function actionB(uint256 _disputeID) private {state=State.ruledB;}
}




contract ArbitratedBuy is TwoPartyArbitrable {
    uint32  public daysToOppose; // Number of days after which the ether are automaticaly given to the seller if no opposition.
    uint256 public price;
    uint256 public timePayment;

    enum State {New, Paid, Blocked}
    State public state;

    /// Create the contract and put the amount needed in it.
    function ArbitratedBuy(uint256 _price, uint32 _daysToOppose, Court _court, uint256 _timeToReac) TwoPartyArbitrable(_court,0,_timeToReac) {
        price=_price;
        daysToOppose=_daysToOppose;
    }

    function pay() payable {
        if (msg.value!=price || state!=State.New) // Verify the price is right and it hasn't been paid yet.
            throw;
        partyB=msg.sender;
        timePayment=now;
    }

    /// Release the money to the buyer.
    function actionA(uint256 _disputeID) private {releaseToBuyer();}

    /// Release the money to the seller.
    function actionB(uint256 _disputeID) private {releaseToSeller();}

    function releaseToSeller() {
        if (msg.sender==partyB || msg.sender==address(court)) // Only buyer and arbitrator can release.
        {
            if (!partyA.send(this.balance))
                throw;
        }
        else
            throw;
    }

    function releaseToBuyer() {
        if (msg.sender==partyA || msg.sender==address(court)) // Only seller and arbitrator can release.
        {
            if (!partyB.send(this.balance))
                throw;
        }
        else
            throw;
    }

    /// If the buyer hasn't receive the product by the deadline he can call this function to prevent the buyer from being able to withdraw the funds
    function block() {
        if (msg.sender!=partyB)
            throw;
        state=State.Blocked;
    }

    function withdrawAfterTime() {
        if (msg.sender!=partyA)
            throw;
        if (state!=State.Paid)
            throw;
        if (now < timePayment+daysToOppose * 1 days)
            throw;
        if(!partyA.send(this.balance))
            throw;
    }

}

contract BuyableCourt is Court{
    function BuyableCourt(address[] accounts, uint256[] tokens) Court(accounts,tokens) {}

    function buyTokens() payable {
        balances[msg.sender]+=msg.value;
    }
}