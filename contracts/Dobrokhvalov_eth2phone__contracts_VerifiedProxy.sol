pragma solidity 0.4.15;
import './SafeMath.sol';
import './Stoppable.sol';

/**
 * @title VerifiedProxy
 * @dev Contract allows to send ether through verifier (owner of contract).
 * 
 * Only verifier can initiate withdrawal to recipient's address. 
 * Verifier cannot choose recipient's address without 
 * verification private key generated by sender. 
 * 
 * Sender is responsible to provide verification private key
 * to recipient off-chain.
 * 
 * Recepient signs address to receive with verification private key and 
 * provides signed address to verification server. 
 * (See VerifyTransferSignature method for details.)
 * 
 * Verifier verifies off-chain the recipient in accordance with verification 
 * conditions (e.g., phone ownership via SMS authentication) and initiates
 * withdrawal to the address provided by recipient.
 * (See withdraw method for details.)
 * 
 * Verifier charges commission for it's services.
 * 
 * Sender is able to cancel transfer if it's not already cancelled or withdrawn
 * by recipient.
 * (See cancelTransfer method for details.)
 */
contract VerifiedProxy is Stoppable, SafeMath {

  // Status codes
  enum Statuses {
    ACTIVE, // awaiting withdrawal
    COMPLETED, // recepient have withdrawn the transfer
    CANCELLED  // sender has cancelled the transfer
  }

  // fixed amount of wei accrued to verifier with each transfer
  uint public commissionFee;

  // verifier can withdraw this amount from smart-contract
  uint public commissionToWithdraw; // in wei

  // gas cost to withdraw transfer
  uint private WITHDRAW_GAS_COST = 80000;

  /*
   * EVENTS
   */
  event LogDeposit(
		   address indexed from,
		   bytes32 indexed transferId,
		   uint amount,
		   uint commission,
		   uint gasPrice // to withdraw with the same gas price
		   );

  event LogCancel(
		  address indexed from,
		  bytes32 indexed transferId,
		                uint amount
		  );

  event LogWithdraw(
		    bytes32 indexed transferId,
		    address indexed sender,
		    address indexed recipient,
		                          uint amount
		    );

  event LogWithdrawCommission(uint commissionAmount);

  event LogChangeFixedCommissionFee(
				    uint oldCommissionFee,
				            uint newCommissionFee
				    );

  struct Transfer {
    uint8 status; // 0 - active, 1 - completed, 2 - cancelled;
    address from;
    uint amount; // in wei
    address verificationPubKey;
  }

  // Mappings of TransferId => Transfer Struct
  mapping (bytes32 => Transfer) transferDct;

  // Mappings of sender address => [transfer ids]
  mapping (address => bytes32[]) senderDct;

  /**
   * @dev Contructor that sets msg.sender as owner (verifier) in Ownable
   * and sets verifier's fixed commission fee.
   * @param _commissionFee uint Verifier's fixed commission for each transfer
   */
  function VerifiedProxy(uint _commissionFee) {
    commissionFee = _commissionFee;
  }


  /**
   * @dev Deposit ether to smart-contract and create transfer.
   * Verification public key is assigned to transfer. 
   * Recipient should sign his address with private key 
   * for verification public key.
   * 
   * @param _verPubKey address Verifification public key.
   * @param _transferId bytes32 Unique transfer id.
   * @return True if success.
   */
  function deposit(address _verPubKey, bytes32 _transferId)
                        whenNotPaused
                        whenNotStopped
                        payable
    returns(bool)
  {
    // can not override old transfer
    require(transferDct[_transferId].verificationPubKey == 0);

    uint transferGasCommission = safeMul(tx.gasprice, WITHDRAW_GAS_COST);
    uint transferCommission = safeAdd(commissionFee,transferGasCommission);
    require(msg.value > transferCommission);

    // saving transfer details
    transferDct[_transferId] = Transfer(
					uint8(Statuses.ACTIVE),
					msg.sender,
					safeSub(msg.value, transferCommission),//amount = msg.value - comission
					_verPubKey // verification public key
					);

    // verification server commission accrued
    commissionToWithdraw = safeAdd(commissionToWithdraw, transferCommission);

    // add transfer to mappings
    senderDct[msg.sender].push(_transferId);

    // log deposit event
    LogDeposit(msg.sender,_transferId,msg.value,transferCommission,tx.gasprice);
    return true;
  }

  /**
   * @dev Change verifier's fixed commission fee.
   * Only owner can change commision fee.
   * 
   * @param _newCommissionFee uint New verifier's fixed commission
   * @return True if success.
   */
  function changeFixedCommissionFee(uint _newCommissionFee)
                      whenNotPaused
                      whenNotStopped
                      onlyOwner
    returns(bool success)
  {
    uint oldCommissionFee = commissionFee;
    commissionFee = _newCommissionFee;
    LogChangeFixedCommissionFee(oldCommissionFee, commissionFee);
    return true;
  }

  /**
   * @dev Transfer accrued commission to verifier's address.
   * @return True if success.
   */
  function withdrawCommission()
                    whenNotPaused
    returns(bool success)
  {
    uint commissionToTransfer = commissionToWithdraw;
    commissionToWithdraw = 0;
    owner.transfer(commissionToTransfer); // owner is verifier

    LogWithdrawCommission(commissionToTransfer);
    return true;
  }

  /**
   * @dev Get transfer details.
   * @param _transferId bytes32 Unique transfer id.
   * @return Transfer details (id, status, sender, amount)
   */
  function getTransfer(bytes32 _transferId)
        constant
    returns (
	     bytes32 id,
	     uint status, // 0 - active, 1 - completed, 2 - cancelled;
	     address from, // transfer sender
	     uint amount) // in wei
  {
    Transfer memory transfer = transferDct[_transferId];
    return (
	    _transferId,
	    transfer.status,
	    transfer.from,
	        transfer.amount
	    );
  }

  /**
   * @dev Get count of sent transfers by msg.sender.
   * @return A number of sent transfers by msg.sender.
   */
  function getSentTransfersCount() constant returns(uint count) {
    return senderDct[msg.sender].length;
  }

  /**
   * @dev Get transfer by index from array of msg.sender's sent transfer ids.
   * @param _transferIndex uint Index in msg.sender's sent transfers array. 
   * @return Transfer details (id, status, sender, amount)
   */
  function getSentTransfer(uint _transferIndex)
            constant
    returns (
	     bytes32 id,
	     uint status, // 0 - pending, 1 - closed, 2 - cancelled;
	     address from, // transfer sender
	     uint amount) // in wei
  {
    bytes32 transferId = senderDct[msg.sender][_transferIndex];
    Transfer memory transfer = transferDct[transferId];
    return (
	    transferId,
	    transfer.status,
	    transfer.from,
	        transfer.amount
	    );
  }

  /**
   * @dev Cancel transfer and get sent ether back. Only transfer sender can
   * cancel transfer.
   * @param _transferId bytes32 Unique transfer id.
   * @return True if success.
   */
  function cancelTransfer(bytes32 _transferId) returns (bool success) {
    Transfer storage transferOrder = transferDct[_transferId];

    // only sender can cancel transfer;
    require(msg.sender == transferOrder.from);

    // only active transfers can be cancelled;
    require(transferOrder.status == uint8(Statuses.ACTIVE));

    // set transfer's status to cancelled.
    transferOrder.status = uint8(Statuses.CANCELLED);

    // transfer ether back to sender
    transferOrder.from.transfer(transferOrder.amount);

    // log cancel event
    LogCancel(msg.sender, _transferId, transferOrder.amount);
    return true;
  }

  /**
   * @dev Verify that address is signed with correct verification private key.
   * @param _verPubKey address Verification public key.
   * @param _recipient address Signed address.
   * @param _v ECDSA signature parameter v.
   * @param _r ECDSA signature parameters r.
   * @param _s ECDSA signature parameters s.
   * @return True if signature is correct.
   */
  function verifySignature(
			   address _verPubKey,
			   address _recipient,
			   uint8 _v,
			   bytes32 _r,
			   bytes32 _s)
    constant returns(bool success)
  {
    bytes32 prefixedHash = sha3("\x19Ethereum Signed Message:\n32", _recipient);
    address retAddr = ecrecover(prefixedHash, _v, _r, _s);
    return retAddr == _verPubKey;
  }

  /**
   * @dev Verify that address is signed with correct private key for
   * verification public key assigned to transfer.
   * @param _transferId bytes32 Transfer Id.
   * @param _recipient address Signed address.
   * @param _v ECDSA signature parameter v.
   * @param _r ECDSA signature parameters r.
   * @param _s ECDSA signature parameters s.
   * @return True if signature is correct.
   */
  function verifyTransferSignature(
				   bytes32 _transferId,
				   address _recipient,
				   uint8 _v,
				   bytes32 _r,
				   bytes32 _s)
    constant returns(bool success)
  {
    Transfer memory transferOrder = transferDct[_transferId];
    return (verifySignature(transferOrder.verificationPubKey,
			    _recipient, _v, _r, _s));
  }

  /**
   * @dev Withdraw transfer to recipient's address if it is correctly signed
   * with private key for verification public key assigned to transfer.
   * 
   * @param _transferId bytes32 Transfer Id.
   * @param _recipient address Signed address.
   * @param _v ECDSA signature parameter v.
   * @param _r ECDSA signature parameters r.
   * @param _s ECDSA signature parameters s.
   * @return True if success.
   */
  function withdraw(
		    bytes32 _transferId,
		    address _recipient,
		    uint8 _v,
		    bytes32 _r,
		    bytes32 _s)
    onlyOwner // only through verifier can withdraw transfer;
        whenNotPaused
        whenNotStopped
    returns (bool success)
  {
    Transfer storage transferOrder = transferDct[_transferId];

    // only active transfers can be withdrawn;
    require(transferOrder.status == uint8(Statuses.ACTIVE));

    // verifying signature
    require(verifySignature(transferOrder.verificationPubKey,
			    _recipient, _v, _r, _s ));

    // set transfer's status to completed.
    transferOrder.status = uint8(Statuses.COMPLETED);

    // transfer ether to recipient's address
    _recipient.transfer(transferOrder.amount);

    // log withdraw event
    LogWithdraw(_transferId, transferOrder.from, _recipient, transferOrder.amount);
    return true;
  }


  // fallback function - do not receive ether by default
  function() payable {
    revert();
  }
}