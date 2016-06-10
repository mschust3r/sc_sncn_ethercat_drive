/**
 * @file ethercat_setup.h
 * @brief EtherCAT Node Setup: Please define your the node structure and configuration for each node.
 * @author Synapticon GmbH <support@synapticon.com>
 */

#ifndef ETHERCAT_SETUP_H_
#define ETHERCAT_SETUP_H_

/**
 * SOMANET Slave Configuration
 */
#define TOTAL_NUM_OF_SLAVES 1

#define SLAVE_ALIAS                    0
#define SLAVE_POSITION                 0
#define SLAVE_CONFIG_NUMBER            1
#define SLAVE_POSITION_IN_SLV_HANDLES  0

SOMANET_C22_CTRLPROTO_CSTRUCT();

/* Slave Handles Array for single node
  Note: Each array entry defines handle struct for a node */
static ctrlproto_slv_handle slv_handles[]=
{
    SOMANET_C22_CTRLPROTO_SLAVE_HANDLES_ENTRY(SLAVE_ALIAS, SLAVE_POSITION, SLAVE_CONFIG_NUMBER),
    SOMANET_C22_CTRLPROTO_SLAVE_HANDLES_ENTRY(SLAVE_ALIAS, 1, 2),
    SOMANET_C22_CTRLPROTO_SLAVE_HANDLES_ENTRY(SLAVE_ALIAS, 2, 3),
    SOMANET_C22_CTRLPROTO_SLAVE_HANDLES_ENTRY(SLAVE_ALIAS, 3, 4),
    SOMANET_C22_CTRLPROTO_SLAVE_HANDLES_ENTRY(SLAVE_ALIAS, 4, 5),
    SOMANET_C22_CTRLPROTO_SLAVE_HANDLES_ENTRY(SLAVE_ALIAS, 5, 6)
};

/* Domain entries for the pdos
 * Note: Each array entry define pdos for a node
 */
const static ec_pdo_entry_reg_t domain_regs[] = {
    SOMANET_C22_CTRLPROTO_DOMAIN_REGS_ENTRIES(SLAVE_ALIAS, SLAVE_POSITION,   SLAVE_POSITION_IN_SLV_HANDLES),
#if(TOTAL_NUM_OF_SLAVES >= 2)
    SOMANET_C22_CTRLPROTO_DOMAIN_REGS_ENTRIES(SLAVE_ALIAS, SLAVE_POSITION+1, SLAVE_POSITION_IN_SLV_HANDLES+1),
#endif
#if(TOTAL_NUM_OF_SLAVES >= 3)
    SOMANET_C22_CTRLPROTO_DOMAIN_REGS_ENTRIES(SLAVE_ALIAS, SLAVE_POSITION+2, SLAVE_POSITION_IN_SLV_HANDLES+2),
#endif
#if(TOTAL_NUM_OF_SLAVES >= 4)
    SOMANET_C22_CTRLPROTO_DOMAIN_REGS_ENTRIES(SLAVE_ALIAS, SLAVE_POSITION+3, SLAVE_POSITION_IN_SLV_HANDLES+3),
#endif
#if(TOTAL_NUM_OF_SLAVES >= 5)
    SOMANET_C22_CTRLPROTO_DOMAIN_REGS_ENTRIES(SLAVE_ALIAS, SLAVE_POSITION+4, SLAVE_POSITION_IN_SLV_HANDLES+4),
#endif
#if(TOTAL_NUM_OF_SLAVES >= 6)
    SOMANET_C22_CTRLPROTO_DOMAIN_REGS_ENTRIES(SLAVE_ALIAS, SLAVE_POSITION+5, SLAVE_POSITION_IN_SLV_HANDLES+5),
#endif
    {0}
};

/*
 * Master setup struct
 */
MASTER_SETUP_INIT();


/**
 * Increase priority of the master process
 * !! YOU WILL NEED TO RUN THIS AS ROOT OTHERWISE THE PRIORITY WILL NOT CHANGE!!
 */
#define PRIORITY

#endif /* ETHERCAT_SETUP_H_ */
